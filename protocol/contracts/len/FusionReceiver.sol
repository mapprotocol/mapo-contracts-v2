// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IReceiver} from "../interfaces/IReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseImplementation} from "@mapprotocol/common-contracts/contracts/base/BaseImplementation.sol";

interface ITSSGateway {
    function bridgeOutWithOrderId(
        bytes32 orderId,
        address token,
        uint256 amount,
        uint256 toChain,
        bytes memory to,
        address refundAddr,
        bytes memory payload,
        uint256 deadline
    ) external payable returns(bytes32);
}
interface IMOS {
    struct BridgeParam {
        bool relay;
        address referrer;
        bytes32 transferId;
        uint256 gasLimit;
        bytes swapData;
    }

    function swapOutTokenWithOrderId(
        address _initiator, // initiator address
        address _token, // src token
        bytes memory _to,
        uint256 _amount,
        uint256 _toChain, // target chain id
        bytes32 orderId,
        bytes calldata _bridgeData
    ) external payable returns (bytes32);
}

contract FusionReceiver is BaseImplementation, IReceiver {
    using SafeERC20 for IERC20;
    uint256 constant public MINGASFORSTORE = 80000;

    enum ReceiveType { BUTTER, TSS }

    IMOS public mos;
    
    ITSSGateway public gateway;

    address public forwardTssFailedReceiver;

    mapping(bytes32 => bool) public stored;

    error only_self();
    error only_mos_or_gateway();
    error transaction_not_exist();

    struct ReceivedStruct {
        ReceiveType receiveType;
        bytes32 orderId;
        address token;
        uint256 amount;
        uint256 fromChain;
        bytes from;
        bytes payload;
    }

    event Set(address _mos, address _gateway);
    event SetForwardTssFailedReceiver(address _failedReceiver);
    event EmergencyWithdraw(IERC20 token, uint256 amount, address receiver);
    event TransactionConnect(bytes32 orderId, bool fromTss);
    event FailedStore(
        ReceiveType _receiveType,
        bytes32 _orderId,
        address _token,
        uint256 _amount,
        uint256 _fromChain,
        bytes _from,
        bytes _payload
    );


    function set(address _mos, address _gateway) external restricted {
        require(_mos != address(0) && _gateway != address(0));
        mos = IMOS(_mos);
        gateway = ITSSGateway(_gateway);
        emit Set(_mos, _gateway);
    }

    function setForwardTssFailedReceiver(address _failedReceiver) external restricted {
        require(_failedReceiver != address(0));
        forwardTssFailedReceiver = _failedReceiver;
        emit SetForwardTssFailedReceiver(_failedReceiver);
    }

    function initialize(address _defaultAdmin) public initializer {
        __BaseImplementation_init(_defaultAdmin);
    }


    function onReceived(
        bytes32 _orderId,
        address _token,
        uint256 _amount,
        uint256 _fromChain,
        bytes calldata _from,
        bytes calldata _payload
    ) external {
        // Authenticate the caller before anything is stored, otherwise anyone could
        // plant a fake failed record via the low-gas branch and get it retried.
        if (msg.sender != address(mos) && msg.sender != address(gateway)) revert only_mos_or_gateway();
        ReceivedStruct memory rs = _assignment(_orderId, _token, _amount, _fromChain, _from, _payload);
        rs.receiveType = (msg.sender == address(mos)) ? ReceiveType.BUTTER : ReceiveType.TSS;
        // When paused (or short of gas), only record; never forward funds.
        // Reverting is not an option: callers wrap onReceived in try/catch after the
        // tokens were already transferred, so a revert would lose the record.
        if (paused() || gasleft() < MINGASFORSTORE) {
            _store(rs);
            return;
        }
        uint256 gasForCall = gasleft() - MINGASFORSTORE;
        if (msg.sender == address(mos)) {
           try this.forwardToGateway{gas: gasForCall}(rs) {
                emit TransactionConnect(_orderId, false);
           } catch  {
                _store(rs);
           }
        } else if (msg.sender == address(gateway)) {
            try this.forwardToMos{gas: gasForCall}(rs) {
                emit TransactionConnect(_orderId, true);
            } catch  {
                _store(rs);
            }
        }
    }

    function retry(
        ReceiveType _receiveType,
        bytes32 _orderId,
        address _token,
        uint256 _amount,
        uint256 _fromChain,
        bytes calldata _from,
        bytes calldata _payload
    ) external restricted whenNotPaused {
        ReceivedStruct memory rs = _assignment(_orderId, _token, _amount, _fromChain, _from, _payload);
        bytes32 hash = _getReceiveHash(_receiveType, rs.orderId, rs.token, rs.amount, rs.fromChain, rs.from, rs.payload);
        if (!stored[hash]) revert transaction_not_exist();
        stored[hash] = false;
        if (_receiveType == ReceiveType.TSS) {
            _forwardToMos(rs);
            emit TransactionConnect(rs.orderId, true);
        } else {
            _forwardToGateway(rs);
            emit TransactionConnect(rs.orderId, false);
        }
    }

    function forwardToMos(ReceivedStruct memory rs) external {
        if (msg.sender != address(this)) revert only_self();
        _forwardToMos(rs);
    }

    function _forwardToMos(ReceivedStruct memory rs) internal {
        (bytes memory to,  uint256 toChain) = abi.decode(rs.payload, (bytes,uint256));
        IERC20(rs.token).approve(address(mos), rs.amount);
        mos.swapOutTokenWithOrderId(address(this), rs.token, to, rs.amount, toChain, rs.orderId, bytes(""));
    }

    function forwardToGateway(ReceivedStruct memory rs) external {
        if (msg.sender != address(this)) revert only_self();
        _forwardToGateway(rs);
    }

    function _forwardToGateway(ReceivedStruct memory rs) internal {
        (bytes memory to,  uint256 toChain) = abi.decode(rs.payload, (bytes,uint256));
        address refundAddr = (forwardTssFailedReceiver == address(0)) ? address(this) : forwardTssFailedReceiver;
        IERC20(rs.token).approve(address(gateway), rs.amount);
        gateway.bridgeOutWithOrderId(rs.orderId, rs.token, rs.amount, toChain, to, refundAddr, abi.encode(bytes(""), bytes(""), bytes("")), (block.timestamp + 100));
    }


    function _store(ReceivedStruct memory rs) internal {
        bytes32 hash = _getReceiveHash(rs.receiveType, rs.orderId, rs.token, rs.amount, rs.fromChain, rs.from, rs.payload);
        stored[hash] = true;
        emit FailedStore(rs.receiveType, rs.orderId, rs.token, rs.amount, rs.fromChain, rs.from, rs.payload);
    }

    function _getReceiveHash(
        ReceiveType _receiveType,
        bytes32 _orderId,
        address _token,
        uint256 _amount,
        uint256 _fromChain,
        bytes memory _from,
        bytes memory _payload
    ) internal pure returns(bytes32 hash) {
        // payload (destination + chain) is bound into the hash so retry cannot redirect funds
        hash = keccak256(abi.encode(_receiveType, _orderId, _token, _amount, _fromChain, _from, _payload));
    }


    function _assignment(
        bytes32 _orderId,
        address _token,
        uint256 _amount,
        uint256 _fromChain,
        bytes memory _from,
        bytes memory _payload
    ) internal pure returns(ReceivedStruct memory rs) {
        rs.orderId = _orderId;
        rs.token = _token;
        rs.amount = _amount;
        rs.fromChain = _fromChain;
        rs.from = _from;
        rs.payload = _payload;
    }

    function emergencyWithdraw(IERC20 token, uint256 amount, address receiver) external restricted {
        require(receiver != address(0));
        IERC20(token).safeTransfer(receiver, amount);
        emit EmergencyWithdraw(token, amount, receiver);
    }
}
