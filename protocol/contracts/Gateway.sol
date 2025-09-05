// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IReceiver} from "./interfaces/IReceiver.sol";
import {TxType} from "./libs/Types.sol";
import {IMintableToken} from "./interfaces/IMintableToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {BaseImplementation} from "@mapprotocol/common-contracts/contracts/base/BaseImplementation.sol";

contract Gateway is BaseImplementation, ReentrancyGuardUpgradeable {
    address internal constant ZERO_ADDRESS = address(0);
    uint256 internal constant MIN_GAS_FOR_LOG = 20_000;

    uint256 constant MINTABLE_TOKEN = 0x03;
    uint256 constant BRIDGABLE_TOKEN = 0x01;

    uint256 public immutable selfChainId = block.chainid;

    bytes public tss;
    bytes public retireTss;
    uint256 public retireSequence;
    uint256 private nonce;

    address public wToken;
    mapping(bytes32 => bool) private orderExecuted;

    // token => feature
    mapping(address => uint256) public tokenFeatureList;

    mapping (bytes32 => bool) public failedHash;

    event SetWToken(address _wToken);
    event UpdateTokens(address token, uint256 feature);
    event UpdateTSS(bytes32 orderId, bytes fromTss, bytes toTss);

    event BridgeOut(
        bytes32 indexed orderId,
        // fromChain (8 bytes) | toChain (8 bytes) | reserved (16 bytes)
        uint256 indexed chainAndGasLimit,
        TxType txOutType,
        bytes vault,
        address token,
        uint256 amount,
        address from,
        bytes to,
        bytes payload
    );

    event BridgeIn(
        bytes32 indexed orderId,
        // fromChain (8 bytes) | toChain (8 bytes) | reserved (8 bytes) | gasUsed (8 bytes)
        uint256 indexed chainAndGasLimit,
        TxType txInType,
        bytes vault,
        uint256 sequence,
        address sender,     // maintainer, will receive gas on relay chain
        address token,
        uint256 amount,
        bytes from,
        address to,
        bytes data          // migration: new vault
    );

    event BridgeFailed(
        bytes32 indexed orderId,
        address token,
        uint256 amount,
        bytes from,
        address to,
        bytes data,
        bytes reason
    );

    error transfer_in_failed();
    error transfer_out_failed();
    error order_executed();
    error zero_address();
    error invalid_signature();
    error not_bridge_able();
    error invalid_target_chain();
    error invalid_vault();
    error invalid_in_tx_type();

    function setWtoken(address _wToken) external restricted {
        require(_wToken != ZERO_ADDRESS);
        wToken = _wToken;
        emit SetWToken(_wToken);
    }

    function setTssAddress(bytes calldata _tss) external restricted {
        require(tss.length == 0 && _tss.length != 0);
        tss = _tss;
        emit UpdateTSS(bytes32(0), bytes(""), _tss);
    }


    function updateTokens(address[] calldata _tokens, uint256 _feature) external restricted {
        for (uint256 i = 0; i < _tokens.length; i++) {
            tokenFeatureList[_tokens[i]] = _feature;
            emit UpdateTokens(_tokens[i], _feature);
        }
    }

    function isMintable(address _token) external view returns (bool) {
        return _isMintable(_token);
    }

    function _isMintable(address _token) internal view returns (bool) {
        return (tokenFeatureList[_token] & MINTABLE_TOKEN) == MINTABLE_TOKEN;
    }

    function isBridgeable(address _token) external view returns (bool) {
        return _isBridgeAble(_token);
    }

    function _isBridgeAble(address _token) internal view returns(bool) {
        ((tokenFeatureList[_token] & BRIDGABLE_TOKEN) == BRIDGABLE_TOKEN);
    }

    function deposit(address token, uint256 amount, address to, address refund)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (bytes32 orderId)
    {
        require(amount != 0);
        address user = msg.sender;
        if (to == ZERO_ADDRESS) revert zero_address();
        bytes memory receiver = abi.encodePacked(to);
        address outToken = _safeReceiveToken(token, user, amount);
        orderId = _getOrderId(user, outToken, amount);
        address from = (refund == address(0)) ? user : refund;
        emit BridgeOut(orderId, selfChainId << 192, TxType.DEPOSIT, tss, outToken, amount, from, receiver, bytes(""));
    }

    function bridgeOut(address token, uint256 amount, uint256 toChain, bytes memory to, address refund, bytes memory payload)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (bytes32 orderId)
    {
        require(amount != 0 && toChain != selfChainId);
        address user = msg.sender;
        address outToken = _safeReceiveToken(token, user, amount);
        orderId = _getOrderId(user, outToken, amount);
        address from = (refund == address(0)) ? user : refund;
        uint256 chainAndGasLimit = selfChainId << 192 | toChain << 128;
        emit BridgeOut(orderId, chainAndGasLimit, TxType.TRANSFER, tss, outToken, amount, from, to, payload);
    }

    struct BridgeInParams {
        uint256 chainAndGasLimit;
        TxType txType;
        uint256 sequence;
        address token;
        uint256 amount;
        address to;
        bytes from;
        bytes payload;
    }

    function bridgeIn(bytes32 orderId, bytes calldata vault, bytes calldata params, bytes calldata signature) external whenNotPaused nonReentrant {
        if (orderExecuted[orderId]) revert order_executed();
        if (!_checkSignature(orderId, vault, params, signature)) revert invalid_signature();
        BridgeInParams memory bridgeParam;
        bytes memory to;
        bytes memory token;
        (bridgeParam.chainAndGasLimit, bridgeParam.txType, bridgeParam.sequence, token, bridgeParam.amount, bridgeParam.from, to, bridgeParam.payload) = 
        abi.decode(params, (uint256,TxType,uint256,bytes,uint256,bytes,bytes,bytes));
        _checkVault(bridgeParam.sequence, vault);
        _checkTargetChain(bridgeParam.chainAndGasLimit);
        bridgeParam.token = _fromBytes(token);
        bridgeParam.to = _fromBytes(to);
        emit BridgeIn(
            orderId, bridgeParam.chainAndGasLimit, bridgeParam.txType, vault, bridgeParam.sequence, msg.sender, bridgeParam.token, bridgeParam.amount, bridgeParam.from, bridgeParam.to, bridgeParam.payload
        );
        if(bridgeParam.txType == TxType.MIGRATE) {
           _updateTSS(orderId, bridgeParam.sequence, bridgeParam.payload);
        } else if(bridgeParam.txType == TxType.TRANSFER || bridgeParam.txType == TxType.REFUND) {
           _bridgeTokenIn(orderId, bridgeParam);
        } else {
            revert invalid_in_tx_type();
        }
    }

    function _bridgeTokenIn(bytes32 orderId, BridgeInParams memory param) internal {
        if(param.amount > 0 && param.to != address(0)) {
            bool call = _needCall(param.to, param.payload.length);
            bool result = _safeTransferOut(param.token, param.to, param.amount, call);
            if (result) {
                if(call) {
                    uint256 fromChain = param.chainAndGasLimit >> 192;
                    uint256 gasForCall = gasleft() - MIN_GAS_FOR_LOG;
                    try IReceiver(param.to).onReceived{gas: gasForCall}(orderId, param.token, param.amount, fromChain, param.from, param.payload) {} catch {}
                }
                return;
            }
        }
        _bridgeFailed(orderId, param, bytes("transferFailed"));
    }

    function _updateTSS(bytes32 orderId, uint256 sequence, bytes memory newVault) internal whenNotPaused nonReentrant {
        retireTss = tss;
        tss = newVault;
        retireSequence = sequence;
        emit UpdateTSS(orderId, retireTss, newVault);
    }

    function _bridgeFailed(bytes32 orderId, BridgeInParams memory param, bytes memory reason) internal {
        bytes32 hash = keccak256(abi.encodePacked(
            orderId,
            param.token, 
            param.amount,
            param.from,
            param.to,
            param.payload
        ));
        failedHash[hash] = true;
        emit BridgeFailed(
            orderId,
            param.token,
            param.amount,
            param.from,
            param.to,
            param.payload,
            reason
        );
    }

    function isOrderExecuted(bytes32 orderId) external view returns (bool) {
        return orderExecuted[orderId];
    }

    function _safeTransferOut(address token, address to, uint256 value, bool needCall)
        internal
        returns (bool result)
    {
        address _wToken = wToken;
        if (token == _wToken && !needCall) {
            bool success;
            bytes memory data;
            // unwrap wToken
            (success, data) = _wToken.call(abi.encodeWithSelector(0x2e1a7d4d, value));
            result = (success && (data.length == 0 || abi.decode(data, (bool))));
            if (result) {
                // transfer native token to the recipient
                (success, data) = to.call{value: value}("");
            } else {
                // if unwrap failed, fallback to transfer wToken
                (success, data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
            }
            result = (success && (data.length == 0 || abi.decode(data, (bool))));
        } else {
            if(_isMintable(token)) IMintableToken(token).mint(address(this), value);
            // bytes4(keccak256(bytes('transfer(address,uint256)')));  transfer
            (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
            result = (success && (data.length == 0 || abi.decode(data, (bool))));
        }
    }

    function _safeReceiveToken(address token, address from, uint256 value) internal returns (address outToken) {
        address to = address(this);
        if (token == ZERO_ADDRESS) {
            outToken = wToken;
            if (msg.value != value) revert transfer_in_failed();
            // wrap native token
            (bool success, bytes memory data) = outToken.call{value: value}(abi.encodeWithSelector(0xd0e30db0));
            if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
                revert transfer_in_failed();
            }
        } else {
            outToken = token;
            uint256 balanceBefore = IERC20(token).balanceOf(to);
            // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));  transferFrom
            (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
            if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
                revert transfer_in_failed();
            }
            uint256 balanceAfter = IERC20(token).balanceOf(to);
            if (balanceAfter - balanceBefore != value) revert transfer_in_failed();
            if(_isMintable(outToken)) IMintableToken(outToken).burn(value);
        }
        if(!_isBridgeAble(outToken)) revert not_bridge_able();
    }

    function _checkSignature(bytes32 orderId, bytes calldata vault, bytes calldata params, bytes calldata signature) internal pure returns (bool) {
        bytes32 hash = keccak256(abi.encodePacked(orderId, params));
        address signer = ECDSA.recover(hash, signature);
        return signer == _publicKeyToAddress(vault);
    }

    function _checkVault(uint256 sequence, bytes memory vault) internal view {
       if(!_checkBytes(_getTss(sequence), vault)) revert invalid_vault();
    }

    function _checkTargetChain(uint256 chainAndGasLimit) internal view {
        uint256 tochain = (chainAndGasLimit >> 128) & (1 << 64 - 1);
        if(tochain != selfChainId) revert invalid_target_chain(); 
    }

    function _publicKeyToAddress(bytes calldata publicKey) public pure returns (address) {
        return address(uint160(uint256(keccak256(publicKey))));
    }

    function _needCall(address target, uint256 len) internal view returns (bool) {
        return (len > 0 && target.code.length > 0);
    }

    function _getTss(uint256 sequence) internal view returns (bytes memory _tss) {
        _tss = (sequence > retireSequence) ? tss : retireTss;
    }

    function _getOrderId(address user, address token, uint256 amount) internal returns (bytes32 orderId) {
        return keccak256(abi.encodePacked(selfChainId, user, token, amount, ++nonce));
    }

    function _checkBytes(bytes memory a, bytes memory b) internal pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }

    function _fromBytes(bytes memory b) internal pure returns (address addr) {
        assembly {
            addr := mload(add(b, 20))
        }
    }
}
