// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IGateway} from "../interfaces/IGateWay.sol";

import {IReceiver} from "../interfaces/IReceiver.sol";
import {IMintableToken} from "../interfaces/periphery/IMintableToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {BaseImplementation} from "@mapprotocol/common-contracts/contracts/base/BaseImplementation.sol";

import {TxType, BridgeItem, TxItem} from "../libs/Types.sol";
import {Utils} from "../libs/Utils.sol";

abstract contract BaseGateway is IGateway, BaseImplementation, ReentrancyGuardUpgradeable {
    address internal constant ZERO_ADDRESS = address(0);
    uint256 internal constant MIN_GAS_FOR_LOG = 20_000;
    uint256 internal constant MIN_GAS_FOR_ON_RECEIVED = 300_000;

    bytes32 internal constant ORDER_NOT_EXIST = bytes32(0);
    bytes32 internal constant ORDER_EXECUTED = bytes32(uint256(1));

    uint256 constant TOKEN_BRIDGEABLE = 0x01;
    uint256 constant TOKEN_MINTABLE = 0x02;
    uint256 constant TOKEN_BURNFROM = 0x04;


    uint256 public immutable selfChainId = block.chainid;

    uint256 internal nonce;

    address public wToken;

    address public transferFailedReceiver;

    mapping(bytes32 => bytes32) internal orderExecuted;

    // token => feature
    mapping(address => uint256) public tokenFeatureList;

    // mapping(bytes32 => bool) public failedHash;

    event SetWToken(address _wToken);
    event UpdateTokens(address token, uint256 feature);

    event BridgeOut(
        bytes32 indexed orderId,
        // fromChain (8 bytes) | toChain (8 bytes) | reserved (16 bytes)
        uint256 indexed chainAndGasLimit,
        TxType txOutType,
        bytes vault,
        address token,
        uint256 amount,
        address from,
        address refundAddr,
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
        address sender,  // maintainer, will receive gas on relay chain
        address token,
        uint256 amount,
        //bytes from,
        address to,
        bytes data      // migration: new vault
    );
    event SetTransferFailedReceiver(address _transferFailedReceiver);
    event BridgeFailed(bytes32 indexed orderId, address token, uint256 amount, bytes data, bytes reason);

    error transfer_in_failed();
    error transfer_out_failed();

    error zero_address();
    error invalid_refund_address();
    error not_bridge_able();
    error expired();
    error call_on_received_gas_too_low();

    modifier ensure(uint deadline) {
        if(deadline < block.timestamp) revert expired();
        _;
    }
    receive() external payable {}

    function setWtoken(address _wToken) external restricted {
        require(_wToken != ZERO_ADDRESS);
        wToken = _wToken;
        emit SetWToken(_wToken);
    }

    function updateTokens(address[] calldata _tokens, uint256 _feature) external restricted {
        for (uint256 i = 0; i < _tokens.length; i++) {
            tokenFeatureList[_tokens[i]] = _feature;
            if(_isSupportBurnFrom(_tokens[i])) {
                IERC20(_tokens[i]).approve(address(this), type(uint256).max);
            }
            emit UpdateTokens(_tokens[i], _feature);
        }
    }

    function setTransferFailedReceiver(address _transferFailedReceiver) external restricted {
        require(_transferFailedReceiver != address(0));
        transferFailedReceiver = _transferFailedReceiver;

        emit SetTransferFailedReceiver(_transferFailedReceiver);
    }

    function isOrderExecuted(bytes32 orderId, bool) external view virtual returns (bool) {
        return (orderExecuted[orderId] != ORDER_NOT_EXIST);
    }

    function isMintable(address _token) external view returns (bool) {
        return _isMintable(_token);
    }

    function isBridgeable(address _token) external view returns (bool) {
        return _isBridgeable(_token);
    }


    function deposit(address token, uint256 amount, address to, address refundAddr, uint256 deadline)
    external
    payable
    override
    whenNotPaused
    nonReentrant
    ensure(deadline)
    returns (bytes32 orderId)
    {
        require(amount != 0);
        address user = msg.sender;
        if (to == ZERO_ADDRESS) revert zero_address();
        if (refundAddr == ZERO_ADDRESS) revert invalid_refund_address();

        address outToken = _safeReceiveToken(token, user, amount);
        orderId = _getOrderId(user);

        _deposit(orderId, outToken, amount, user, to, refundAddr);

        return orderId;
    }


    function bridgeOut(
        address token,
        uint256 amount,
        uint256 toChain,
        bytes memory to,
        address refundAddr,
        bytes memory payload,
        uint256 deadline
    ) external payable override whenNotPaused nonReentrant ensure(deadline) returns (bytes32 orderId) {
        require(amount != 0 && toChain != selfChainId && to.length != 0);
        if (refundAddr == ZERO_ADDRESS) revert invalid_refund_address();

        // address user = msg.sender;
        address outToken = _safeReceiveToken(token, msg.sender, amount);
        if (!_isBridgeable(outToken)) revert not_bridge_able();

        // address from = (refund == address(0)) ? user : refund;
        // uint256 chainAndGasLimit = selfChainId << 192 | toChain << 128;
        orderId = _getOrderId(msg.sender);
        emit BridgeOut(
            orderId,
            // uint256 chainAndGasLimit = selfChainId << 192 | toChain << 128;
            (selfChainId << 192 | toChain << 128),
            TxType.TRANSFER,
            _getActiveVault(),
            outToken,
            amount,
            msg.sender,
            refundAddr,
            to,
            payload
        );

        _bridgeOut(orderId, outToken, amount, toChain, to, payload);

        return orderId;
    }


    function _deposit(bytes32 orderId, address token, uint256 amount, address from, address to, address refundAddr)
    internal
    virtual;

    function _bridgeOut(
        bytes32 orderId,
        address token,
        uint256 amount,
        uint256 toChain,
        bytes memory to,
        bytes memory payload
    ) internal virtual {}

    function _bridgeTokenIn(bytes32 hash, BridgeItem memory bridgeItem, TxItem memory txItem) internal {
        
        if(bridgeItem.to.length == 20) {
            address to = Utils.fromBytes(bridgeItem.to);

            if (txItem.amount > 0 && to != address(0)) {
                bool needCall = _needCall(to, bridgeItem.payload.length);
                if (_safeTransferOut(txItem.token, to, txItem.amount, needCall)) {
                    if(needCall) {
                        uint256 fromChain = bridgeItem.chainAndGasLimit >> 192;
                        uint256 gasForCall = gasleft() - MIN_GAS_FOR_LOG;
                        if(gasForCall < MIN_GAS_FOR_ON_RECEIVED) revert call_on_received_gas_too_low();
                        try IReceiver(to).onReceived{gas: gasForCall}(
                            txItem.orderId, txItem.token, txItem.amount, fromChain, bridgeItem.from, bridgeItem.payload
                        ) {} catch {}
                    }
                    return;
                }
            }
        }

        if(txItem.amount > 0) {
            address _transferFailedReceiver = transferFailedReceiver;
            if(_transferFailedReceiver != address(0)) {
                _transferOut(txItem.token, _transferFailedReceiver, txItem.amount);
            }
        }
        _bridgeFailed(hash, bridgeItem,  txItem, bytes("transferFailed"));
    }

    function _bridgeFailed(bytes32 hash, BridgeItem memory bridgeItem, TxItem memory txItem, bytes memory reason) internal {
        if (hash == bytes32(0x00)) {
            hash = _getSignHash(txItem.orderId, bridgeItem);
        }
        // failedHash[hash] = true;
        // save item hash for retry
        orderExecuted[txItem.orderId] = hash;
        bytes memory bridgeData = abi.encode(bridgeItem);
        emit BridgeFailed(txItem.orderId, txItem.token, txItem.amount, bridgeData, reason);
    }

    function _safeTransferOut(address token, address to, uint256 value, bool needCall) internal returns (bool result) {
        address _wToken = wToken;
        if(token == _wToken && !needCall) {
            bool success;
            bytes memory data;
            // unwrap wToken
            (success, data) = _wToken.call(abi.encodeWithSelector(0x2e1a7d4d, value));
            result = (success && (data.length == 0 || abi.decode(data, (bool))));
            if(result) token = ZERO_ADDRESS;
        }
        result = _transferOut(token, to, value);
    }

    function _transferOut(address token, address to, uint256 value) internal returns(bool result) {
        if(token == ZERO_ADDRESS) {
            (result,) = to.call{value: value}("");
        } else {
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));
            token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
            uint256 balanceAfter = IERC20(token).balanceOf(address(this));
            result = (balanceBefore == (balanceAfter + value));
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
            _transferFromToken(from, token, value, to);
        }
    }

    function _transferFromToken(address from, address token, uint256 amount, address receiver) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(receiver);
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)'))); transferFrom
        token.call(abi.encodeWithSelector(0x23b872dd, from, receiver, amount));
        uint256 balanceAfter = IERC20(token).balanceOf(receiver);
        if (balanceAfter != (balanceBefore + amount)) revert transfer_in_failed();
    }

    function _getActiveVault() internal view virtual returns (bytes memory vault);

    function _getOrderId(address user) internal returns (bytes32 orderId) {
        return keccak256(abi.encodePacked(address(this), selfChainId, user, ++nonce));
    }

    function _checkAndBurn(address _token, uint256 _amount) internal {
        if (_isMintable(_token)) {
            if(_isSupportBurnFrom(_token)) {
                IMintableToken(_token).burnFrom(address(this), _amount);
                return;
            }
            IMintableToken(_token).burn(_amount);
        } 
    }

    function _checkAndMint(address _token, uint256 _amount) internal {
        if (_isMintable(_token)) {
            IMintableToken(_token).mint(address(this), _amount);
        }
    }

    function _getFromAndToChain(uint256 chainAndGasLimit) internal pure returns (uint256, uint256) {
        uint256 fromChain = chainAndGasLimit >> 192;
        uint256 toChain = chainAndGasLimit >> 128 & 0xFFFFFFFFFFFFFFFF;

        return (fromChain, toChain);
    }

    function _getSignHash(bytes32 orderId, BridgeItem memory bridgeItem)
    internal
    pure
    returns (bytes32)
    {
        // payload length might be long
        // use payload hash to optimize the encodePacked gas
        bytes32 payloadHash = keccak256(bridgeItem.payload);
        bytes32 hash = keccak256(
            abi.encodePacked(
                orderId,
                bridgeItem.chainAndGasLimit,
                bridgeItem.txType,
                bridgeItem.vault,
                bridgeItem.sequence,
                bridgeItem.token,
                bridgeItem.amount,
                bridgeItem.from,
                bridgeItem.to,
                payloadHash
            )
        );

        return hash;
    }

    function _isMintable(address _token) internal view returns (bool) {
        return (tokenFeatureList[_token] & TOKEN_MINTABLE) == TOKEN_MINTABLE;
    }

    function _isBridgeable(address _token) internal view returns (bool) {
        return ((tokenFeatureList[_token] & TOKEN_BRIDGEABLE) == TOKEN_BRIDGEABLE);
    }

    function _isSupportBurnFrom(address _token) internal view returns (bool) {
        return ((tokenFeatureList[_token] & TOKEN_BURNFROM) == TOKEN_BURNFROM);
    }

    function _needCall(address target, uint256 len) internal view returns (bool) {
        return (len > 0 && target.code.length > 0);
    }
}
