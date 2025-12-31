// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Utils} from "./libs/Utils.sol";
import {IRelay} from "./interfaces/IRelay.sol";
// import {ITSSManager} from "./interfaces/ITSSManager.sol";
import {IRegistry, ContractType} from "./interfaces/IRegistry.sol";
import {IGasService} from "./interfaces/IGasService.sol";
import {IVaultManager} from "./interfaces/IVaultManager.sol";
import {ISwap} from "./interfaces/swap/ISwap.sol";
import {IAffiliateFeeManager} from "./interfaces/affiliate/IAffiliateFeeManager.sol";

import {TxType, TxInItem, TxOutItem, ChainType, TxItem, GasInfo, BridgeItem} from "./libs/Types.sol";

import {Errs} from "./libs/Errors.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {BaseGateway} from "./base/BaseGateway.sol";

contract Relay is BaseGateway, IRelay {

    mapping(uint256 => uint256) private chainSequence;
    mapping(uint256 => uint256) private chainLastScanBlock;

    // todo: save in/out tx hash?
    mapping(bytes32 => bool) private outOrderExecuted;

    IRegistry public registry;
    IVaultManager public vaultManager;

    struct OrderInfo {
        bool signed;
        uint64 height;
        address gasToken;
        uint128 estimateGas;
        bytes32 hash;
    }

    mapping(bytes32 => OrderInfo) public orderInfos;

    event SetRegistry(address _registry);
    event SetVaultManager(address _vaultManager);
    event SetAffiliateFeeManager(address _affiliateFeeManager);

    event AddChain(uint256 chain);
    event RemoveChain(uint256 chain);

    event Withdraw(address token, address reicerver, uint256 vaultAmount, uint256 tokenAmount);

    event Deposit(bytes32 orderId, uint256 fromChain, address token, uint256 amount, address to, bytes from);

    event TransferIn(bytes32 orderId, address token, uint256 amount, address to, bool result);

    event BridgeRelay(
        bytes32 indexed orderId,
        // fromChain (8 bytes) | toChain (8 bytes) | txRate (8 bytes) | txSize (8 bytes)
        uint256 indexed chainAndGasLimit,
        TxType txType,
        bytes vault,
        bytes to,
        bytes token,
        uint256 amount,
        uint256 sequence,
        // tss sign base on this hash
        // abi.encodePacked(orderId | chainAndGasLimit | txOutType | vault | sequence | token | amount| from | to | keccak256(data)
        bytes32 hash,
        bytes from,
        // tokenOut: bytes(payload)
        // migrate: bytes("vault")
        bytes data
    );


    event BridgeRelaySigned(
        bytes32 indexed orderId,
        // fromChain (8 bytes) | toChain (8 bytes) | txRate (8 bytes) | txSize (8 bytes)
        uint256 indexed chainAndGasLimit,
        bytes vault,
        bytes relayData,
        bytes signature
    );

    event BridgeCompleted(
        bytes32 indexed orderId,
        // fromChain (8 bytes) | toChain (8 bytes) | reserved (16 bytes)
        uint256 indexed chainAndGasLimit,
        TxType txOutType,
        bytes vault,
        uint256 sequence,
        address sender,
        bytes data
    );

    event BridgeError(bytes32 indexed orderId, string reason);
    event BridgeFeeCollected(bytes32 indexed orderId, address token, uint256 protocolFee);

    function initialize(address _defaultAdmin) public initializer {
        __BaseImplementation_init(_defaultAdmin);
    }

    function setVaultManager(address _vaultManager) external restricted {
        require(_vaultManager != address(0));
        vaultManager = IVaultManager(_vaultManager);
        emit SetVaultManager(_vaultManager);
    }

    function setRegistry(address _registry) external restricted {
        require(_registry != address(0));
        registry = IRegistry(_registry);
        emit SetRegistry(_registry);
    }

    function addChain(
        uint256 _chain,
        uint256 _lastScanBlock
    ) external restricted {
        if (!registry.isRegistered(_chain)) revert Errs.chain_not_registered();

        _updateLastScanBlock(_chain, uint64(_lastScanBlock));
        vaultManager.addChain(_chain);

        emit AddChain(_chain);
    }

    function removeChain(uint256 _chain) external restricted {
        // check vault migration
        bool completed = vaultManager.checkMigration();
        if (!completed) revert Errs.migration_not_completed();
        vaultManager.removeChain(_chain);

        emit AddChain(_chain);
    }


    function isOrderExecuted(bytes32 orderId, bool isTxIn) external view override returns (bool executed) {
        executed = isTxIn ? (orderExecuted[orderId] != ORDER_NOT_EXIST) : outOrderExecuted[orderId];
    }


    function getChainLastScanBlock(uint256 chain) external view override returns(uint256) {
        return chainLastScanBlock[chain];
    }

    function redeem(address _vaultToken, uint256 _vaultShare, address receiver) external whenNotPaused {
        address user = msg.sender;

        (address asset, uint256 amount) = vaultManager.redeem(_vaultToken, _vaultShare, user, receiver);
        if(amount > 0) _sendToken(asset, amount, receiver, false);

        emit Withdraw(_vaultToken, user, _vaultShare, amount);
    }


    function rotate(bytes memory retiringVault, bytes memory activeVault) external override {
        _checkAccess(ContractType.TSS_MANAGER);

        vaultManager.rotate(retiringVault, activeVault);
    }

    function migrate() external override returns (bool) {
        _checkAccess(ContractType.TSS_MANAGER);

        (bool completed, TxItem memory txItem, GasInfo memory gasInfo, bytes memory fromVault, bytes memory toVault) = vaultManager.migrate();
        if (completed) {
            return true;
        }
        if (txItem.chain == 0) {
            // no need do more migration, waiting for all migration completed
            return false;
        }

        txItem.orderId = _getOrderId(address(this));

        BridgeItem memory bridgeItem;
        bridgeItem.vault = fromVault;
        bridgeItem.payload = toVault;
        bridgeItem.txType = TxType.MIGRATE;

        _emitRelay(selfChainId, bridgeItem, txItem, gasInfo);

        return false;
    }

    function relaySigned(bytes32 orderId, bytes calldata relayData, bytes calldata signature)
        external
    {
        OrderInfo storage order = orderInfos[orderId];
        if (order.signed) return;

        BridgeItem memory outItem = abi.decode(relayData, (BridgeItem));

        bytes32 hash = _getSignHash(orderId, outItem);
        if (hash != order.hash) revert Errs.invalid_signature();

        address signer = ECDSA.recover(hash, signature);
        if (signer != Utils.getAddressFromPublicKey(outItem.vault)) revert Errs.invalid_signature();

        order.signed = true;
        _updateLastScanBlock(selfChainId, order.height);

        emit BridgeRelaySigned(orderId, outItem.chainAndGasLimit, outItem.vault, relayData, signature);
    }

    // todo: add block hash
    function postNetworkFee(
        uint256 chain,
        uint256 height,
        uint256 transactionSize,
        uint256 transactionSizeWithCall,
        uint256 transactionRate
    ) external override {
        _checkAccess(ContractType.TSS_MANAGER);

        IGasService gasService = IGasService(registry.getContractAddress(ContractType.GAS_SERVICE));
        gasService.postNetworkFee(chain, height, transactionSize, transactionSizeWithCall, transactionRate);
    }

    function executeTxOut(TxOutItem calldata txOutItem) external override {
        _checkAccess(ContractType.TSS_MANAGER);

        if (outOrderExecuted[txOutItem.orderId]) revert Errs.order_executed();

        outOrderExecuted[txOutItem.orderId] = true;

        BridgeItem calldata bridgeItem = txOutItem.bridgeItem;

        (, uint256 chain) = _getFromAndToChain(bridgeItem.chainAndGasLimit);
        if(chain == selfChainId) return;

        _updateLastScanBlock(chain, txOutItem.height);

        TxItem memory txItem = _getTxItem(txOutItem.orderId, bridgeItem, chain);

        OrderInfo memory order = orderInfos[txOutItem.orderId];

        uint256 usedGas = order.estimateGas;
        if (txItem.chainType != ChainType.CONTRACT) {
            usedGas = registry.getRelayChainGasAmount(chain, txOutItem.gasUsed);
        }

        if (vaultManager.checkVault(txItem)) {
            uint256 gasForSender = 0;
            uint256 transferAmount = 0;

            // (txItem.token, txItem.amount) = _getRelayTokenAndAmount(chain, bridgeItem.token, bridgeItem.amount);

            if (bridgeItem.txType == TxType.MIGRATE) {
                (gasForSender, transferAmount) = vaultManager.migrationComplete(txItem, bridgeItem.payload, uint128(usedGas), order.estimateGas);
            } else {
                (gasForSender, transferAmount) = vaultManager.transferComplete(txItem, uint128(usedGas), order.estimateGas);
            }
            if (gasForSender > 0) {
                _sendToken(txItem.token, gasForSender, txOutItem.sender, true);
            }
            if (transferAmount > 0) {
                _checkAndBurn(txItem.token, transferAmount);
            }

        } else {
            // refund from retired vault on non-contract vault
            // no need update vault balance
        }

        delete orderInfos[txOutItem.orderId];

        emit BridgeCompleted(
            txOutItem.orderId,
            txOutItem.bridgeItem.chainAndGasLimit,
            txOutItem.bridgeItem.txType,
            txOutItem.bridgeItem.vault,
            txOutItem.bridgeItem.sequence,
            txOutItem.sender,
            txOutItem.bridgeItem.payload
        );
    }

    // swap: affiliate data | relay data | target data
    function executeTxIn(TxInItem calldata txInItem) external override {
        _checkAccess(ContractType.TSS_MANAGER);

        if (orderExecuted[txInItem.orderId] != ORDER_NOT_EXIST) revert Errs.order_executed();
        orderExecuted[txInItem.orderId] = ORDER_EXECUTED;

        BridgeItem calldata bridgeItem = txInItem.bridgeItem;

        (uint256 fromChain, uint256 toChain) = _getFromAndToChain(bridgeItem.chainAndGasLimit);

        _updateLastScanBlock(fromChain, txInItem.height);

        TxItem memory txItem = _getTxItem(txInItem.orderId, bridgeItem, fromChain);

        if (!vaultManager.checkVault(txItem)) {
            // refund if vault is retired
            return _refund(bridgeItem.from, txInItem.refundAddr, bridgeItem.vault, txItem, true);
        }

        _checkAndMint(txItem.token, txItem.amount);
        // update source vault and relay chain vault balance
        vaultManager.updateFromVault(txItem, toChain);

        bytes memory affiliateData;
        bytes memory relayData;
        bytes memory targetData;
        try this.validateTxInParam(toChain, bridgeItem) returns (bytes memory _affiliateData, bytes memory _relayData, bytes memory _targetData) {
            affiliateData = _affiliateData;
            relayData = _relayData;
            targetData = _targetData;
        } catch  {
            return _refund(bridgeItem.from, txInItem.refundAddr, bridgeItem.vault, txItem, false);
        }

        if (bridgeItem.txType == TxType.DEPOSIT) {
            address to = Utils.fromBytes(bridgeItem.to);
            _depositIn(txItem, bridgeItem.from, to);
        } else if (bridgeItem.txType == TxType.TRANSFER) {

            // collect affiliate and bridge fee
            txItem.amount = _collectAffiliateAndProtocolFee(txItem, affiliateData);
            if (txItem.amount == 0) {
                // emit complete event
                emit BridgeError(txItem.orderId, "zero out amount");
                return;
            }

            try this.execute(bridgeItem.from, bridgeItem.to, txItem, toChain, relayData, targetData) returns (address token, uint256 amount) {
                if (toChain == selfChainId) {
                    txItem.token = token;
                    txItem.amount = amount;
                    txItem.chain = toChain;
                    txItem.chainType = ChainType.CONTRACT;
                    vaultManager.transferComplete(txItem, 0, 0);
                    emit BridgeCompleted(
                        txItem.orderId,
                        bridgeItem.chainAndGasLimit,
                        bridgeItem.txType,
                        bridgeItem.vault,
                        bridgeItem.sequence,
                        msg.sender,
                        targetData
                    );

                    _bridgeIn(txItem, bridgeItem, targetData);
                }
            } catch (bytes memory) {
                // txItem.chain = fromChain;
                // txItem.chainType = periphery.getChainType(fromChain);

                _refund(bridgeItem.from, txInItem.refundAddr, bridgeItem.vault, txItem, false);

                return;
            }
        }
    }

    function validateTxInParam(uint256 toChain, BridgeItem calldata bridgeItem) external view returns(bytes memory affiliateData, bytes memory relayData, bytes memory targetData) {
        if(bridgeItem.txType == TxType.DEPOSIT) toChain = selfChainId;
        ChainType chainType = registry.getChainType(toChain);
        _checkToAddress(bridgeItem.to, bridgeItem.txType, chainType);
        if(bridgeItem.payload.length > 0) {
            (affiliateData, relayData, targetData) =
                abi.decode(bridgeItem.payload, (bytes, bytes, bytes));
        }
    }

    function _swap(address tokenIn, uint256 amountInt, bytes memory payload) internal returns (address , uint256) {
        (address tokenOut, uint256 amountOutMin) = abi.decode(payload, (address, uint256));
        ISwap swap = ISwap(registry.getContractAddress(ContractType.SWAP));
        _approveToken(tokenIn, amountInt, address(swap));
        uint amountOut = swap.swap(tokenIn, amountInt, tokenOut, amountOutMin);
        _transferFromToken(address(swap), tokenOut, amountOut, address(this));
        return (tokenOut, amountOut);
    }

    function execute(bytes calldata from, bytes calldata to, TxItem calldata txItem, uint256 toChain, bytes calldata relayPayload, bytes calldata targetPayload) public returns (address, uint256) {
        require(msg.sender == address(this));
        return _executeInternal(from, to, txItem, toChain, relayPayload, targetPayload);
    }


    function _executeInternal(bytes memory from, bytes memory to, TxItem memory txItem, uint256 toChain, bytes memory relayPayload, bytes memory targetPayload) internal returns (address, uint256) {
        bool choose;
        GasInfo memory gasInfo;
        BridgeItem memory bridgeOutItem;

        uint256 fromChain = txItem.chain;

        if (relayPayload.length > 0) {
            // 1 collect from chain vault fee and balance fee
            txItem.amount = vaultManager.transferIn(txItem, toChain);

            // 2 swap
            (txItem.token, txItem.amount) = _swap(txItem.token, txItem.amount, relayPayload);

            // todo: update target payload
            txItem.chain = toChain;
            txItem.chainType = registry.getChainType(toChain);

            // 3.1 collect to chain vault fee and balance fee
            // 3.2 calculate to chain gas fee
            // 3.3 choose to chain vault
            // 3.4 update to chain vault
            (choose, txItem.amount, bridgeOutItem.vault, gasInfo) = vaultManager.transferOut(txItem, fromChain, targetPayload.length > 0);
            if (!choose) {
                // no vault
                revert Errs.invalid_vault();
            }
        } else {
            // 1 collect vault fee and balance fee
            // 2.1 calculate to chain gas fee
            // 2.2 choose to chain vault
            // 3 update from chain and to chain vault
            (choose, txItem.amount, bridgeOutItem.vault, gasInfo) = vaultManager.bridgeOut(txItem,toChain,targetPayload.length > 0);
            if (!choose) {
                // no target vault
                revert Errs.invalid_vault();
            }

            txItem.chain = toChain;
            txItem.chainType = registry.getChainType(toChain);
        }

        // todo: check relay min amount

        // 4 emit BridgeRelay event
        if (toChain != selfChainId) {

            bridgeOutItem.from = from;
            bridgeOutItem.to = to;

            bridgeOutItem.payload = targetPayload;
            bridgeOutItem.txType = TxType.TRANSFER;
            _emitRelay(fromChain, bridgeOutItem, txItem, gasInfo);
        }

        return (txItem.token, txItem.amount);
    }

    function _bridgeIn(TxItem memory txItem, BridgeItem memory bridgeItem, bytes memory targetData) internal {
        address to = Utils.fromBytes(bridgeItem.to);
        bridgeItem.payload = targetData;
        emit BridgeIn(
            txItem.orderId,
            bridgeItem.chainAndGasLimit,
            bridgeItem.txType,
            bridgeItem.vault,
            bridgeItem.sequence,
            msg.sender,
            txItem.token,
            txItem.amount,
            to,
            bridgeItem.payload
        );
        _bridgeTokenIn(bytes32(0x00), bridgeItem, txItem);
    }

    function _getActiveVault() internal view override returns (bytes memory vault) {
        return vaultManager.getActiveVault();
    }

    function _deposit(bytes32 _orderId, address _outToken, uint256 _amount, address _from, address _to, address)
        internal
        override
    {
        TxItem memory txItem = TxItem({
            orderId: _orderId,
            chain: selfChainId,
            chainType: ChainType.CONTRACT,
            token: _outToken,
            amount: _amount,
            vaultKey: vaultManager.getActiveVaultKey() });
        // bytes memory vault = vaultManager.getActiveVault();

        _depositIn(txItem,  Utils.toBytes(_from), _to);
    }

    function _bridgeOut(
        bytes32 orderId,
        address token,
        uint256 amount,
        uint256 toChain,
        bytes memory to,
        bytes memory payload
    ) internal override {
        TxItem memory txItem;
        txItem.orderId = orderId;
        txItem.token = token;
        txItem.amount = amount;
        txItem.chain = selfChainId;
        txItem.vaultKey = vaultManager.getActiveVaultKey();

        (bytes memory affiliateData, bytes memory relayPayload, bytes memory targetPayload) =
            abi.decode(payload, (bytes, bytes, bytes));

        // collect affiliate and bridge fee first
        txItem.amount = _collectAffiliateAndProtocolFee(txItem, affiliateData);
        if (txItem.amount == 0) revert Errs.zero_amount_out();

        _executeInternal(Utils.toBytes(msg.sender), to, txItem, toChain, relayPayload, targetPayload);
    }

    function _checkToAddress(bytes memory to, TxType txType, ChainType) internal pure {
        require(to.length > 0);
        if(txType == TxType.DEPOSIT) {
            require(to.length == 20);
            require(Utils.fromBytes(to) != ZERO_ADDRESS);
        }
    }

    function _collectAffiliateAndProtocolFee(TxItem memory txItem, bytes memory affiliateData)
    internal
    returns (uint256)
    {
        uint256 affiliateFee;
        if (affiliateData.length > 0) {
            IAffiliateFeeManager affiliateFeeManager = IAffiliateFeeManager(registry.getContractAddress(ContractType.AFFILIATE));
            try affiliateFeeManager.collectAffiliatesFee(txItem.orderId, txItem.token, txItem.amount, affiliateData) returns (uint256 totalFee) {
                affiliateFee = totalFee;
                _sendToken(txItem.token, affiliateFee, address(affiliateFeeManager), true);
            } catch (bytes memory) {
                // do nothing
            }
        }

        (address receiver, uint256 protocolFee) = registry.getProtocolFee(txItem.token, txItem.amount);
        if(protocolFee > 0) _sendToken(txItem.token, protocolFee, receiver, true);

        uint256 amount = txItem.amount - affiliateFee - protocolFee;

        emit BridgeFeeCollected(txItem.orderId, txItem.token, protocolFee);

        return amount;
    }


    function _updateLastScanBlock(uint256 chain, uint64 height) internal {
        if (height > chainLastScanBlock[chain]) {
            chainLastScanBlock[chain] = height;
        }
    }

    function _refund(bytes calldata from, bytes calldata refundAddress, bytes calldata vault, TxItem memory txItem, bool fromRetiredVault) internal {
        GasInfo memory gasInfo;

        // refund to the from vault
        (txItem.amount, gasInfo) = vaultManager.refund(txItem, fromRetiredVault);
        if (txItem.amount == 0) {
            emit BridgeError(txItem.orderId, "zero out amount");
            return;
        }

        BridgeItem memory bridgeItem;
        bridgeItem.txType = TxType.REFUND;
        bridgeItem.from = from;
        bridgeItem.to = refundAddress;
        bridgeItem.vault = vault;

        _emitRelay(txItem.chain, bridgeItem, txItem, gasInfo);
    }

    function _depositIn(TxItem memory txItem, bytes memory from, address to) internal {
        vaultManager.deposit(txItem, to);

        emit Deposit(txItem.orderId, txItem.chain, txItem.token, txItem.amount, to, from);
    }

    function _sendToken(address token, uint256 amount, address to, bool handle) internal returns (bool result) {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        result = (success && (data.length == 0 || abi.decode(data, (bool))));
        if (!handle && !result) revert Errs.transfer_token_out_failed();
    }

    function _approveToken(address token, uint256 amount, address spender) internal {
        // bytes4(keccak256(bytes('approve(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        bool result = (success && (data.length == 0 || abi.decode(data, (bool))));
        if (!result) revert Errs.approve_token_failed();
    }


    /**
     * @dev Emit bridge relay event and prepare cross-chain transaction
     * Main purpose:
     * 1. Convert token and amount to target chain format
     * 2. Generate sequence number for target chain
     * 3. Store order information including gas estimate and block height
     * 4. Calculate and store signature hash for TSS signing
     * 5. Emit BridgeRelay event for off-chain relayers to process
     *
     * Calling requirements:
     * - Vault must be already selected and updated before calling this function
     * - VaultManager.doTransfer() or similar vault update must be called first
     * - txItem must contain valid orderId, token, amount, and chain information
     * - bridgeItem must contain valid vault, from, to, payload and txType
     *
     * @param fromChain Source chain ID where the transaction originates
     * @param bridgeItem Bridge item containing vault and transaction details
     * @param txItem Transaction item with token and amount information
     * @param gasInfo Estimated gas required for the transaction on target chain
     */
    function _emitRelay(uint256 fromChain, BridgeItem memory bridgeItem, TxItem memory txItem, GasInfo memory gasInfo) internal {

        // non contract migration or token transfer
        if (!(bridgeItem.txType == TxType.MIGRATE && txItem.chainType == ChainType.CONTRACT)) {
            // _checkAndBurn(txItem.token, txItem.amount);
            (bridgeItem.token, bridgeItem.amount) = _getToChainTokenAndAmount(txItem.chain, txItem.token, txItem.amount);
        }

        bridgeItem.chainAndGasLimit =
                        _getChainAndGasLimit(fromChain, txItem.chain, gasInfo.transactionRate, gasInfo.transactionSize);
        bridgeItem.sequence = ++chainSequence[txItem.chain];

        OrderInfo storage order = orderInfos[txItem.orderId];
        order.gasToken = txItem.token;
        order.estimateGas = gasInfo.estimateGas;

        order.hash = _getSignHash(txItem.orderId, bridgeItem);
        order.height = uint64(block.number);

        emit BridgeRelay(
            txItem.orderId,
            bridgeItem.chainAndGasLimit,
            bridgeItem.txType,
            bridgeItem.vault,
            bridgeItem.to,
            bridgeItem.token,
            bridgeItem.amount,
            bridgeItem.sequence,
            order.hash,
            bridgeItem.from,
            bridgeItem.payload
        );
    }

    // function _getRelayTokenAndAmount(uint256 chain, bytes memory fromToken, uint256 fromAmount) internal view returns (address token, uint256 amount){
    //     token = registry.getRelayChainToken(chain, fromToken);
    //     amount = registry.getRelayChainAmount(fromToken, chain, fromAmount);
    //     if(fromAmount > 0 && amount == 0) revert Errs.token_not_registered();
    // }

    function _getToChainTokenAndAmount(uint256 chain, address relayToken, uint256 relayAmount) internal view returns (bytes memory token, uint256 amount){
        token = registry.getToChainToken(relayToken, chain);
        amount = registry.getToChainAmount(relayToken, relayAmount, chain);
        if(relayAmount > 0 && amount == 0) revert Errs.token_not_registered();
    }


    function _getTxItem(bytes32 orderId, BridgeItem calldata bridgeItem, uint256 chain) internal view returns (TxItem memory) {
        TxItem memory txItem;
        txItem.chain = chain;
        txItem.chainType = registry.getChainType(chain);
        txItem.orderId = orderId;
        txItem.vaultKey = Utils.getVaultKey(bridgeItem.vault);
        if(bridgeItem.txType == TxType.MIGRATE && txItem.chainType == ChainType.CONTRACT) {
           txItem.token = registry.getChainBaseToken(chain);
           return txItem;
        }
        
        txItem.token = registry.getRelayChainToken(chain, bridgeItem.token);
        if (txItem.token == ZERO_ADDRESS) revert Errs.token_not_registered();

        txItem.amount = registry.getRelayChainAmount(bridgeItem.token, chain, bridgeItem.amount);
        if (bridgeItem.amount > 0 && txItem.amount == 0) revert Errs.token_not_registered();

        return txItem;
    }

    // function _getOrderId() internal returns (bytes32 orderId) {
    //     return keccak256(abi.encodePacked(selfChainId, address(this), ++nonce));
    // }

    function _getChainAndGasLimit(uint256 _fromChain, uint256 _toChain, uint256 _transactionRate, uint256 _transactionSize)
        internal
        pure
        returns (uint256 chainAndGasLimit)
    {
        chainAndGasLimit = ((_fromChain << 192) | (_toChain << 128) | (_transactionRate << 64) | _transactionSize);
    }

    function _checkAccess(ContractType contractAddress) internal view {
        if (msg.sender != registry.getContractAddress(contractAddress)) revert Errs.no_access();
    }
}
