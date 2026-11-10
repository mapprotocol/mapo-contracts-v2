// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {TxType, BridgeItem, TxItem} from "./libs/Types.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {Utils} from "./libs/Utils.sol";

import {BaseGateway} from "./base/BaseGateway.sol";

contract Gateway is BaseGateway {
    address public activeTssAddress;
    address public retireTssAddress;
    bytes public activeTss;
    bytes public retireTss;
    uint256 public retireSequence;
    uint256 public minGasCallOnReceive;
    event UpdateTSS(bytes32 orderId, bytes fromTss, bytes toTss);

    error order_executed();

    error invalid_signature();

    error invalid_target_chain();
    error invalid_vault();
    error invalid_in_tx_type();

    function initialize(address _defaultAdmin) public initializer {
        __BaseImplementation_init(_defaultAdmin);
    }

    function setTssAddress(bytes calldata _tss) external restricted {
        require(activeTss.length == 0 && _tss.length != 0);
        activeTss = _tss;
        activeTssAddress = Utils.getAddressFromPublicKey(_tss);
        emit UpdateTSS(bytes32(0), bytes(""), _tss);
    }

    function updateMinGasCallOnReceive(uint256 _value) external restricted {
        minGasCallOnReceive = _value;
        emit UpdateMinGasCallOnReceive(_value);
    }

    function _deposit(bytes32 orderId, address outToken, uint256 amount, address from, address to, address refundAddr)
        internal
        override
    {
        bytes memory receiver = abi.encodePacked(to);
        _checkAndBurn(outToken, amount);
        emit BridgeOut(
            orderId, selfChainId << 192, TxType.DEPOSIT, activeTss, outToken, amount, from, refundAddr, receiver, bytes("")
        );
    }

    function _bridgeOut(
        bytes32,
        address token,
        uint256 amount,
        uint256,
        bytes memory,
        bytes memory
    ) internal override {
        _checkAndBurn(token, amount);
    }

    function bridgeIn(address sender, bytes32 orderId, bytes calldata params, bytes calldata signature)
        external
        whenNotPaused
        nonReentrant
    {
        if (orderExecuted[orderId] != ORDER_NOT_EXIST) revert order_executed();

        orderExecuted[orderId] = ORDER_EXECUTED;

        BridgeItem memory bridgeItem = abi.decode(params, (BridgeItem));

        bytes32 hash = _checkVaultSignature(orderId, signature, bridgeItem);

        TxItem memory txItem;
        txItem.orderId = orderId;
        txItem.token = Utils.fromBytes(bridgeItem.token);
        txItem.amount = bridgeItem.amount;

        address to = Utils.fromBytes(bridgeItem.to);

        emit BridgeIn(
            txItem.orderId,
            bridgeItem.chainAndGasLimit,
            bridgeItem.txType,
            bridgeItem.vault,
            bridgeItem.sequence,
            sender,
            txItem.token,
            txItem.amount,
            to,
            bridgeItem.payload
        );

        if (bridgeItem.txType == TxType.MIGRATE) {
            _updateTSS(txItem.orderId, bridgeItem.sequence, bridgeItem.payload);
        } else if (bridgeItem.txType == TxType.TRANSFER || bridgeItem.txType == TxType.REFUND) {
            _checkAndMint(txItem.token, txItem.amount);
            _bridgeTokenIn(hash,bridgeItem, txItem, minGasCallOnReceive);
        } else {
            revert invalid_in_tx_type();
        }
    }

    function _updateTSS(bytes32 orderId, uint256 sequence, bytes memory newVault) internal {
        if (sequence <= retireSequence) revert invalid_vault();
        if (newVault.length == 0) revert invalid_vault();
        if (keccak256(newVault) == keccak256(activeTss)) revert invalid_vault();
        
        retireTss = activeTss;
        retireTssAddress = activeTssAddress;
        activeTss = newVault;
        retireSequence = sequence;
        activeTssAddress = Utils.getAddressFromPublicKey(newVault);

        emit UpdateTSS(orderId, retireTss, newVault);
    }

    function _checkVaultSignature(
        bytes32 orderId,
        bytes calldata signature,
        BridgeItem memory bridgeItem
    ) internal view virtual returns (bytes32) {
        address vaultAddr = Utils.getAddressFromPublicKey(bridgeItem.vault);

        bytes32 hash = _getSignHash(orderId, bridgeItem);
        address signer = ECDSA.recover(hash, signature);
        if (signer != vaultAddr) revert invalid_signature();

        address tssAddr = (bridgeItem.sequence > retireSequence) ? activeTssAddress : retireTssAddress;
        if (tssAddr != vaultAddr) revert invalid_vault();

        ( ,uint256 toChain) = _getFromAndToChain(bridgeItem.chainAndGasLimit);

        if (toChain != selfChainId) revert invalid_target_chain();

        return (hash);
    }

    function _getActiveVault() internal view override returns (bytes memory vault) {
        return activeTss;
    }
}
