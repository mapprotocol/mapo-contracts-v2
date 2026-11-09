// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Utils} from "./libs/Utils.sol";
import {IVaultToken} from "./interfaces/IVaultToken.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";

import {IVaultManager} from "./interfaces/IVaultManager.sol";

import {ChainType, TxItem, GasInfo} from "./libs/Types.sol";
import {Errs} from "./libs/Errors.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {BaseImplementation} from "@mapprotocol/common-contracts/contracts/base/BaseImplementation.sol";
import {Rebalance} from "./libs/Rebalance.sol";

/**
 * @title VaultManager
 * @dev Core vault management contract for cross-chain asset transfers
 *
 * ## Overview
 * VaultManager is responsible for managing vault operations across multiple chains,
 * handling vault rotations, migrations, and tracking token balances and allowances.
 * It maintains both active and retiring vaults to ensure smooth transitions during
 * vault updates.
 *
 * ## Liquidity Management Model
 *
 * The VaultManager implements a hybrid liquidity model for cross-chain asset transfers:
 *
 * - **External Chains (Non-Relay Chains)**: Uses a Lock/Unlock mechanism
 *   - Assets are locked in vault addresses when transferred out from the source chain
 *   - Assets are unlocked from vault addresses when received on the destination chain
 *   - Vault balances are tracked and managed per chain and per token
 *   - Physical asset custody is maintained in designated vault addresses
 *
 * - **Relay Chain**: Uses a Mint/Burn mechanism
 *   - Assets are burned when transferred out from the relay chain
 *   - Assets are minted when received on the relay chain
 *   - No physical vault addresses required for mintable tokens
 *   - Token supply expands/contracts based on cross-chain movements
 *   - Provides efficient liquidity without requiring locked collateral
 * - **Mint/Burn External Chains**:
 *   - Will support in the future
 *   - Mint/Burn token will not affect the token total balance
 *
 * ## Vault Management Principles
 *
 * ### 1. Vault Selection Strategy
 * - **Contract Chains**: Always use the active vault for outgoing transfers by default.
 *   The contract maintains chain-specific vault assignments during migrations.
 * - **Non-Contract Chains**: Select vault based on available token allowances,
 *   prioritizing active vault first, then falling back to retiring vault if needed.
 *
 * ### 2. Refund Mechanism
 * - **Retired Vault**: If a vault is retired (not active or retiring), execute refund
 *   to return assets to the sender.
 * - **Insufficient Funds After Swap**: If after relay chain fee deduction and token swap,
 *   the amount is less than expected minimum, trigger refund. Affiliate fees and
 *   security fees are still deducted before refund.
 *
 * ### 3. Fee Structure for Transfers
 * - **Target Chain Transfer**: Deduct base fee (gas fee) when transferring to target chain.
 *   If balance is below the base fee, initiate refund process.
 * - **Balance Fee**: Additional fees may apply based on vault balance management needs,
 *   can be positive (incentive) or negative (fee) depending on rebalancing requirements.
 *
 * ### 4. Refund Fee Management
 * - **Gas Fee Deduction**: During refund, source chain gas fees are deducted.
 * - **Minimum Amount Check**: If the refund amount after gas fee is below minimum
 *   threshold, the refund is cancelled to avoid dust transactions.
 *
 * ### 5. Migration Process
 * - **Contract Chains**: Only update vault key mappings, no actual asset migration.
 *   The chain is immediately assigned to the new active vault.
 * - **Non-Contract Chains**: Physically migrate assets from retiring vault address
 *   to new active vault address. Migration includes:
 *   - Calculate and reserve gas fees for migration transaction
 *   - Transfer tokens in batches (max 3 migrations per chain)
 *   - Update allowances for both vaults accordingly
 *
 * ### 6. Balance and Allowance Tracking
 * - Maintains per-chain, per-token balance states including:
 *   - Current balance and pending outgoing amounts
 *   - Reserved amounts for confirmed transfers
 *   - Target balances for rebalancing operations
 * - Vault-specific chain allowances track migration status and token limits
 *
 * ### 7. Access Control
 * - Only the Relay contract can invoke state-changing operations
 * - Administrative functions restricted to authorized roles
 * - Periphery contract provides chain configuration and fee calculations
 */
contract VaultManager is BaseImplementation, IVaultManager {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableMap for EnumerableMap.AddressToAddressMap;

    uint256 constant MAX_RATE_UNIT = 1_000_000;         // unit is 0.01 bps

    uint128 private constant MAX_MIGRATION_AMOUNT = 3;
    bytes32 private constant NON_VAULT_KEY = bytes32(0x00);

    uint256 public immutable selfChainId = block.chainid;

    enum MigrationStatus {
        NOT_STARTED,
        MIGRATING,
        MIGRATED
    }

    struct FeeInfo {
        uint256 ammFee;             // reserved for fee to amm provider
        uint256 vaultFee;           //
        uint256 balanceFee;
        bool incentive;
    }

    struct VaultFeeRate {
        uint32  ammVault;           // reserved for fee to amm
        uint32  fromVault;          // the vault fee to swap in token
        uint32  toVault;            // the vault fee to bridge/swap out token

        uint160 reserved;            // reserved for future use
    }

    struct ChainTokenVault {
        uint128 balance;
        uint128 pendingOut;

        bool isAdded;           // whether token has been added to chain vault
        uint8 migrationIndex;
    }

    // non-contract chain vault
    struct NativeChainVault {
        // todo: only support native token now
        // the native token will be the first one, and will be migrated at last
        address[] tokens;
        mapping(address => ChainTokenVault) tokenVaults;
    }

    struct Vault {
        EnumerableSet.UintSet chains;
        bytes pubkey;
        // set true after start a migration, reset after migration txOut on relay chain.
        mapping(uint256 chain => MigrationStatus) migrationStatus;
        mapping(uint256 chain => NativeChainVault) chainVaults;
    }

    // not used for mintable token
    struct TokenChainState {
        uint32 weight;              // chain weight for target balance
        uint128 minAmount;          // minimum out amount
        uint128 reserved;           // reserved for transfer out
        uint128 maxCredit;          // reserved
        int128 balance;             // token balance, might be negative value when token is minted
        uint128 pendingOut;         // token pendingOut balance
    }

    struct TokenState {
        uint32 deltaSMax;
        uint32 totalWeight;
        uint128 balance;
        uint128 pendingOut;

        mapping(uint256 => TokenChainState) chainStates;
    }

    address public relay;
    IRegistry public registry;

    VaultFeeRate public vaultFeeRate;
    Rebalance.BalanceFeeRate public balanceFeeRate;

    // only one active vault and one retiring vault at a time
    // after migration, only one active vault, no retiring vault
    bytes32 public activeVaultKey;
    bytes32 public retiringVaultKey;

    mapping(bytes32 vaultKey => Vault) private vaultList;

    EnumerableSet.UintSet private chainList;        // all support chains

    // token => vaultToken
    EnumerableMap.AddressToAddressMap private tokenList;

    mapping(address => TokenState) private tokenStates;

    // token => amount
    mapping(address => uint256) public balanceFees;

    // reserved for migration gas
    mapping(address => uint256) public reservedFees;

    event SetRelay(address _relay);
    event SetRegistry(address _registry);

    event RegisterToken(address indexed _token, address _vaultToken);

    event FeeCollected(bytes32 indexed orderId, address token, uint256 vaultFee, uint256 ammVaultFee, uint256 balanceFee, bool incentive);

    event UpdateTokenWeight(address indexed token, uint256 chain, uint32 weight);
    event UpdateBalanceIndicator(address indexed token, uint32 totalWeight, uint32 deltaMax);

    event UpdateVaultFeeRate(VaultFeeRate _vaultFeeRate);

    event UpdateBalanceFeeRate(Rebalance.BalanceFeeRate _vaultFeeRate);

    event SetMinAmount(address indexed token, uint256 indexed chain, uint128 minAmount);

    modifier onlyRelay() {
        if (msg.sender != address(relay)) revert Errs.no_access();
        _;
    }

    function initialize(address _defaultAdmin) public initializer {
        __BaseImplementation_init(_defaultAdmin);
    }

    // --------------------------------------------- manage ----------------------------------------------

    function setRelay(address _relay) external restricted {
        require(_relay != address(0));
        relay = _relay;
        emit SetRelay(_relay);
    }

    function setRegistry(address _registry) external restricted {
        require(_registry != address(0));
        registry = IRegistry(_registry);
        emit SetRegistry(_registry);
    }

    function registerToken(address _token, address _vaultToken) external restricted {
        // todo: check token register

        IVaultToken vault = IVaultToken(_vaultToken);
        if (_token != vault.asset()) revert Errs.invalid_vault_token();

        if (vault.vaultManager() != address(this)) revert Errs.invalid_vault_token();

        tokenList.set(_token, _vaultToken);

        emit RegisterToken(_token, _vaultToken);
    }

    function updateVaultFeeRate(VaultFeeRate calldata _vaultFeeRate) external restricted {
        require(_vaultFeeRate.ammVault < MAX_RATE_UNIT);
        require(_vaultFeeRate.fromVault < MAX_RATE_UNIT);
        require(_vaultFeeRate.toVault < MAX_RATE_UNIT);
        vaultFeeRate = _vaultFeeRate;
        emit UpdateVaultFeeRate(_vaultFeeRate);
    }


    function updateBalanceFeeRate(Rebalance.BalanceFeeRate calldata _balanceFeeRate) external restricted {
        require(_balanceFeeRate.balanceThreshold < MAX_RATE_UNIT);
        require(_balanceFeeRate.fixedFromBalance > -int32(int256(MAX_RATE_UNIT)) && _balanceFeeRate.fixedFromBalance < int32(int256(MAX_RATE_UNIT)));
        require(_balanceFeeRate.fixedToBalance > -int32(int256(MAX_RATE_UNIT)) && _balanceFeeRate.fixedToBalance < int32(int256(MAX_RATE_UNIT)));
        require(_balanceFeeRate.minBalance > -int32(int256(MAX_RATE_UNIT)) && _balanceFeeRate.minBalance < int32(int256(MAX_RATE_UNIT)));
        require(_balanceFeeRate.maxBalance > -int32(int256(MAX_RATE_UNIT)) && _balanceFeeRate.maxBalance < int32(int256(MAX_RATE_UNIT)));
        require(_balanceFeeRate.minBalance < _balanceFeeRate.maxBalance);
        balanceFeeRate = _balanceFeeRate;
        emit UpdateBalanceFeeRate(_balanceFeeRate);
    }


    function updateTokenWeights(address token, uint256[] memory chains, uint256[] memory weights) external restricted {
        uint256 len = chains.length;
        require(len == weights.length);

        uint256 i;
        uint256 chain;

        TokenState storage tokenState = tokenStates[token];
        for (i = 0; i < len; i++) {
            chain = chains[i];

            TokenChainState storage chainState = tokenState.chainStates[chain];
            uint32 weight = uint32(weights[i]);
            tokenState.totalWeight = tokenState.totalWeight - chainState.weight + weight;
            chainState.weight = weight;

            emit UpdateTokenWeight(token, chain, weight);
        }

        _updateBalanceIndicator(token);
    }


    function addChain(uint256 chain) external override onlyRelay {
        chainList.add(chain);
        // vaultList[activeVaultKey].chains.add(chain);

        // todo: emit event
    }

    function removeChain(uint256 chain) external override onlyRelay {
        if (retiringVaultKey != NON_VAULT_KEY) revert Errs.migration_not_completed();

        // check all balance
        uint256 length = tokenList.length();
        for (uint256 i = 0; i < length; i++) {
            (address token, ) = tokenList.at(i);
            TokenState storage s = tokenStates[token];
            if (s.chainStates[chain].balance > 0) revert Errs.token_allowance_not_zero();
            if (s.chainStates[chain].weight > 0) {
                s.totalWeight -= s.chainStates[chain].weight;

                _updateBalanceIndicator(token);
            }
            delete s.chainStates[chain];
        }

        NativeChainVault storage v = vaultList[activeVaultKey].chainVaults[chain];
        length = v.tokens.length;
        for (uint256 i = 0; i < length; i++) {
            address token = v.tokens[i];
            if (v.tokenVaults[token].balance > 0) revert Errs.token_allowance_not_zero();
            delete v.tokenVaults[token];
        }
        delete v.tokens;

        _removeChainFromVault(activeVaultKey, chain);

        chainList.remove(chain);

        // todo: emit event
    }

    function setMinAmount(address token, uint256 chain, uint128 minAmount) external restricted {
        TokenChainState storage state = tokenStates[token].chainStates[chain];
        state.minAmount = minAmount;
        emit SetMinAmount(token, chain, minAmount);
    }

    // ------------------------------------------- public view --------------------------------------------

    function checkMigration() external view override returns (bool completed) {
       completed = (retiringVaultKey == NON_VAULT_KEY);
    }

    function checkVault(TxItem calldata txItem) external view returns (bool) {
        if (txItem.chainType == ChainType.CONTRACT) {
            // checked by source gateway contract for a contract chain
            return true;
        }
        // bytes32 vaultKey = keccak256(vault);
        return (txItem.vaultKey == retiringVaultKey || txItem.vaultKey == activeVaultKey);
    }

    function getActiveVaultKey() external view override returns (bytes32) {
        return activeVaultKey;
    }

    function getActiveVault() external view override returns (bytes memory) {
        return vaultList[activeVaultKey].pubkey;
    }

    function getRetiringVault() external view override returns (bytes memory) {
        if (retiringVaultKey != NON_VAULT_KEY) return vaultList[retiringVaultKey].pubkey;
        else return bytes("");
    }

    function getVaultToken(address relayToken) external view override returns(address) {
        return tokenList.get(relayToken);
    }

    function getBridgeChains() external view override returns(uint256[] memory) {
        return chainList.values();
    }

    function getBridgeTokens() external view override returns (address[] memory){
        return tokenList.keys();
    }

    function getVaultFeeRate() external view returns (uint32 ammVault, uint32 fromVault, uint32 toVault) {
        VaultFeeRate memory rate = vaultFeeRate;
        ammVault = rate.ammVault;
        fromVault = rate.fromVault;
        toVault = rate.toVault;
    }

    function getRelayOutMinAmount(address token, uint256 toChain) external view override returns (uint128) {
        return _getRelayOutMinAmount(token, toChain);
    }

   function getVaultTokenBalance(bytes calldata vault, uint256 chain, address token) external view returns(int256 balance, uint256 pendingOut) {
       bytes32 vaultKey = Utils.getVaultKey(vault);
       ChainType chainType = registry.getChainType(chain);
       if (chainType == ChainType.CONTRACT) {
            TokenChainState storage state =  tokenStates[token].chainStates[chain];
            balance = state.balance;
            pendingOut = state.pendingOut;
       } else {
            ChainTokenVault storage chainTokenVault = vaultList[vaultKey].chainVaults[chain].tokenVaults[token];
            balance = int128(chainTokenVault.balance);
            pendingOut = chainTokenVault.pendingOut;
       }
   }

    function getBalanceFee(uint256 fromChain, uint256 toChain, address token, uint256 amount)
    external
    view
    override
    returns (bool, uint256)
    {
        return _getBalanceFee(fromChain, toChain, token, amount, false, false);
    }

    // --------------------------------------------- external ----------------------------------------------

    function rotate(bytes calldata retiringVault, bytes calldata activeVault) external override onlyRelay {
        if (retiringVaultKey != NON_VAULT_KEY) revert Errs.migration_not_completed();
        if (activeVaultKey != NON_VAULT_KEY && Utils.getVaultKey(retiringVault) != activeVaultKey) revert Errs.invalid_active_vault();
        retiringVaultKey = activeVaultKey;
        activeVaultKey = Utils.getVaultKey(activeVault);
        vaultList[activeVaultKey].pubkey = activeVault;
    }

    function migrate()
    external
    override
    onlyRelay
    returns (bool completed, TxItem memory txItem, GasInfo memory gasInfo, bytes memory fromVault, bytes memory toVault)
    {
        // check the retiring vault first
        if (retiringVaultKey == NON_VAULT_KEY) {
            // no retiring vault, no need migration
            return (true, txItem, gasInfo, bytes(""), bytes(""));
        }

        Vault storage v = vaultList[retiringVaultKey];
        uint256[] memory chains = v.chains.values();
        
        completed = true;
        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chain = chains[i];
            if (chain == selfChainId) {
                // relay chain no need migration
                _removeChainFromVault(retiringVaultKey, chain);
                continue;
            }

            if (v.migrationStatus[chain] == MigrationStatus.MIGRATING) {
                completed = false;
                // migrating, continue to other chain migration
                continue;
            } else if (v.migrationStatus[chain] == MigrationStatus.MIGRATED) {
                txItem.chainType = registry.getChainType(chain);
                if (txItem.chainType == ChainType.CONTRACT) {
                    _removeChainFromVault(retiringVaultKey, chain);
                    continue;
                }
                v.migrationStatus[chain] = MigrationStatus.NOT_STARTED;
            }

            bool chainCompleted;
            (chainCompleted, txItem, gasInfo) = _migrate(chain);
            // migration Completed remove the chain from retiring vault and continue
            if(chainCompleted) {
                _removeChainFromVault(retiringVaultKey, chain);
                continue;
            }
            // no contract chain and pendingOut != 0, not completed, set completed to false and continue
            if (txItem.amount == 0 && txItem.chainType != ChainType.CONTRACT) {
                completed = false;
                continue;
            } 
            return (false, txItem, gasInfo, vaultList[retiringVaultKey].pubkey, vaultList[activeVaultKey].pubkey);
        }

        txItem.chain = 0;
        txItem.amount = 0;
        if(completed) retiringVaultKey = NON_VAULT_KEY;
        return (completed, txItem, gasInfo, bytes(""), bytes(""));
    }



     function bridgeOut(TxItem calldata txItem, uint256 toChain, bool withCall) external onlyRelay override returns (bool choose, uint256 outAmount, bytes memory toVault, GasInfo memory gasInfo) {
         // bytes32 vaultKey = keccak256(fromVault);

         TxItem memory txOutItem;
         txOutItem.orderId = txItem.orderId;
         txOutItem.token = txItem.token;
         txOutItem.chain = toChain;
         txOutItem.chainType = registry.getChainType(toChain);

         txOutItem.amount = _collectFee(txItem.orderId, txItem.chain, toChain, txItem.token, txItem.amount, false, false);

         uint256 totalOutAmount;
         (txOutItem.vaultKey, outAmount, totalOutAmount, gasInfo) = _chooseVault(txOutItem, withCall);
         if (txOutItem.vaultKey == NON_VAULT_KEY) {
             // no vault
             return (false, 0, bytes(""), gasInfo);
         }

         // _updateFromVault(vaultKey, txItem, false);

         _updateToVaultPending(txOutItem.vaultKey, txOutItem.chainType, txOutItem.chain, txOutItem.token, uint128(totalOutAmount),   false);

         return (true, outAmount, vaultList[txOutItem.vaultKey].pubkey, gasInfo);
     }

    function updateFromVault(TxItem calldata txItem, uint256) external onlyRelay override {
        // bytes32 vaultKey = keccak256(fromVault);
        _updateFromVault(txItem.vaultKey, txItem, false);
    }


    // collect transfer in fee
    function transferIn(TxItem calldata txItem, uint256) external onlyRelay override returns (uint256 outAmount) {
        // bytes32 vaultKey = keccak256(fromVault);
        // _updateFromVault(vaultKey, txItem, false);
        outAmount = _collectFee(txItem.orderId, txItem.chain, selfChainId, txItem.token, txItem.amount, true, false);

        return outAmount;
    }

    function transferOut(TxItem calldata txItem, uint256, bool withCall) external onlyRelay override returns (bool choose, uint256 outAmount, bytes memory vault, GasInfo memory gasInfo) {
        TxItem memory txOutItem = txItem;
        txOutItem.amount = _collectFee(txItem.orderId, selfChainId, txItem.chain,  txItem.token, txItem.amount, false, true);

        // bytes32 vaultKey;
        uint256 totalOutAmount;
        (txOutItem.vaultKey, outAmount, totalOutAmount, gasInfo) = _chooseVault(txOutItem, withCall);
        if (txOutItem.vaultKey == NON_VAULT_KEY) {
            // no vault
            return (false, 0, bytes(""), gasInfo);
        }
        _updateToVaultPending(txOutItem.vaultKey, txOutItem.chainType, txOutItem.chain, txOutItem.token, uint128(totalOutAmount), false);

        return (true, outAmount, vaultList[txOutItem.vaultKey].pubkey, gasInfo);
    }


    function refund(TxItem calldata txItem, bool fromRetiredVault)
    external
    onlyRelay
    returns (uint256, GasInfo memory)
    {
        GasInfo memory gasInfo = registry.getNetworkFeeInfoWithToken(txItem.token, txItem.chain,false);
        uint128 minAmount = gasInfo.estimateGas + _getRelayOutMinAmount(txItem.token, txItem.chain);
        if (fromRetiredVault) {
            // no vault balance update for retired vault
            if (txItem.amount <= minAmount) {
                return (0, gasInfo);
            }
            // the native chain vault, keep gas for the refund tx
            return ((txItem.amount - gasInfo.estimateGas), gasInfo);
        }

        uint256 outAmount = _collectFee(txItem.orderId, selfChainId, txItem.chain,  txItem.token, txItem.amount, false, true);
        outAmount = _truncation(outAmount);
        if (outAmount <= minAmount) {
            // out of gas, save as reserved fee and return
            reservedFees[txItem.token] += outAmount;
            return (0, gasInfo);
        }

        uint128 refundAmount = uint128(outAmount) - gasInfo.estimateGas;

        uint128 totalAmountOut = refundAmount;
        if (txItem.chainType == ChainType.NATIVE) {
            totalAmountOut = uint128(outAmount);
        }
        _updateToVaultPending(txItem.vaultKey,  txItem.chainType, txItem.chain, txItem.token, totalAmountOut, false);

        return (refundAmount, gasInfo);
    }


    function deposit(TxItem calldata txItem, address to)
    external
    onlyRelay
    {
        IVaultToken vaultToken = IVaultToken(tokenList.get(txItem.token));

        // todo: check maximum deposit amount

        vaultToken.deposit(txItem.amount, to);
    }

    function redeem(address _vaultToken, uint256 _share, address _owner, address _receiver) external override onlyRelay  returns (address, uint256)  {
        require(_share > 0);
        if(_receiver == address(0)) revert Errs.zero_address();

        IVaultToken vaultToken = IVaultToken(_vaultToken);
        address redeemToken = vaultToken.asset();
        // check vault token: the registered vault token of the asset must be the given one
        (bool exist, address registeredVaultToken) = tokenList.tryGet(redeemToken);
        if (!exist || registeredVaultToken != _vaultToken) revert Errs.invalid_vault_token();
        uint256 redeemAmount = vaultToken.redeem(_share, _receiver, _owner);

        uint256 outAmount = _collectFee(bytes32(0x00), selfChainId, selfChainId, redeemToken, redeemAmount, true, false);

        // _updateToVaultPending(activeVaultKey, ChainType.CONTRACT,  selfChainId,  redeemToken, uint128(outAmount), false);

        return (redeemToken, outAmount);
    }

    // tx out, remove liquidity or swap out
    function transferComplete(TxItem calldata txItem,uint128 usedGas, uint128 estimatedGas) external override onlyRelay returns (uint256 reimbursedGas, uint256 amount) {
        // bytes32 vaultKey = keccak256(vault);

        if (txItem.vaultKey != retiringVaultKey && txItem.vaultKey != activeVaultKey) revert Errs.invalid_vault();

        _updateToVaultComplete(txItem.vaultKey, txItem, usedGas, estimatedGas, false);
        if (txItem.chainType == ChainType.CONTRACT) {
            return (estimatedGas, txItem.amount);
        }
        // save not used gas
        // todo: check usedGas > estimatedGas
        if (estimatedGas > usedGas) {
            reservedFees[txItem.token] += (estimatedGas - usedGas);
        }
        return (0, (txItem.amount + usedGas));
    }


    function migrationComplete(TxItem calldata txItem, bytes calldata toVault, uint128 usedGas, uint128 estimatedGas)
    external
    override
    onlyRelay returns (uint256 reimbursedGas, uint256 amount)
    {
        // bytes32 vaultKey = keccak256(fromVault);
        bytes32 targetVaultKey = Utils.getVaultKey(toVault);
        if (txItem.vaultKey != retiringVaultKey || targetVaultKey != activeVaultKey) revert Errs.invalid_vault();

        vaultList[txItem.vaultKey].migrationStatus[txItem.chain] = MigrationStatus.MIGRATED;
        if (txItem.chainType == ChainType.CONTRACT) {
            reimbursedGas = registry.getMigrateGasFee(txItem.chain, txItem.token, estimatedGas);
        } else {
            _updateToVaultComplete(txItem.vaultKey, txItem, usedGas, estimatedGas, true);
            _updateFromVault(targetVaultKey, txItem, true);
            amount = usedGas;
        }

        // use reserved fee to cover migration gas
        if (reservedFees[txItem.token] >= reimbursedGas) {
            reservedFees[txItem.token] -= reimbursedGas;
        } else {
            uint256 decreased = reimbursedGas - reservedFees[txItem.token];
            reservedFees[txItem.token] = 0;

            // use vault token to cover migration gas
            // will incentive from relay chain later
            IVaultToken vaultToken = IVaultToken(tokenList.get(txItem.token));
            vaultToken.decreaseVault(decreased);
            // todo: emit event
        }
    }


    // --------------------------------------------- internal ----------------------------------------------

    function _addVaultToken(bytes32 vaultKey, uint256 chain, address token) internal {
        NativeChainVault storage cv = vaultList[vaultKey].chainVaults[chain];

        if (cv.tokenVaults[token].isAdded) {
            return;
        }
        if (cv.tokens.length == 0) {
            // add native token first
            address nativeToken = registry.getChainGasToken(chain);
            cv.tokens.push(nativeToken);
            cv.tokenVaults[nativeToken].isAdded = true;
            if (token == nativeToken) {
                return;
            }
        }
        // todo: support alt token on non-contract
        // cv.tokens.push(token);
        // cv.tokenVaults[token].isAdded = true;
    }

    function _removeChainFromVault(bytes32 vaultKey, uint256 chain) internal {
        delete vaultList[vaultKey].chainVaults[chain];
        delete vaultList[vaultKey].migrationStatus[chain];
        vaultList[vaultKey].chains.remove(chain);
    }

    function _removeTokenFromVault(bytes32 vaultKey, uint256 _chain, address token, uint128 balance) internal {
        // update token balance
        tokenStates[token].balance -= balance;
        tokenStates[token].chainStates[_chain].balance -= int128(balance);

        NativeChainVault storage v = vaultList[vaultKey].chainVaults[_chain];
        v.tokens.pop();
        delete v.tokenVaults[token];

    }

    function _migrate(uint256 chain) internal returns (bool completed, TxItem memory txItem, GasInfo memory gasInfo) {
        txItem.chainType = registry.getChainType(chain);
        txItem.chain = chain;

        gasInfo = registry.getNetworkFeeInfo(chain,false);

        if (txItem.chainType == ChainType.CONTRACT) {
            vaultList[retiringVaultKey].migrationStatus[chain] = MigrationStatus.MIGRATING;

            // switch to active vault after migration start when choosing vault
            vaultList[activeVaultKey].chains.add(chain);
            return (false, txItem, gasInfo);
        }

        (completed, txItem.token, txItem.amount) = _noncontractMigrate(chain, gasInfo);

        return (completed, txItem, gasInfo);
    }

    // return:
    //      true: completed
    //      false: not completed
    //              amount > 0: new migration
    //              amount = 0: no migration
    function _noncontractMigrate(uint256 _chain, GasInfo memory gasInfo) internal returns (bool completed, address token, uint256 amount) {
        NativeChainVault storage v = vaultList[retiringVaultKey].chainVaults[_chain];
        uint256 tokenLength = v.tokens.length;
        while (tokenLength > 0) {
            token = v.tokens[tokenLength - 1];
            if (token != gasInfo.gasToken) {
                // todo: support multi tokens migration for non-contract chain

                _removeTokenFromVault(retiringVaultKey, _chain, token, 0);
                tokenLength -= 1;

                continue;
            }

            ChainTokenVault storage tokenBalance = v.tokenVaults[token];
            uint128 minAmount = _getRelayOutMinAmount(token, _chain) + gasInfo.estimateGas;
            uint128 available = tokenBalance.balance - tokenBalance.pendingOut;
            if (available <= minAmount) {
                // no need migration
                if (tokenBalance.pendingOut > 0) {
                    // waiting pending out tx
                    return (false, token, 0);
                }

                // ignore the vault
                // update token balance
                _removeTokenFromVault(retiringVaultKey, _chain, token, tokenBalance.balance);
                tokenLength -= 1;

                continue;
            }

            vaultList[retiringVaultKey].migrationStatus[_chain] = MigrationStatus.MIGRATING;

            uint128 migrationAmount = available / (MAX_MIGRATION_AMOUNT - tokenBalance.migrationIndex);
            if (migrationAmount <= minAmount || (available - migrationAmount) <= minAmount) {
                migrationAmount = available;
            }
            migrationAmount = uint128(_truncation(migrationAmount));
            // keep (MAX_MIGRATION_AMOUNT - tokenBalance.migrationIndex) != 0 for next migration
            if(MAX_MIGRATION_AMOUNT - tokenBalance.migrationIndex > 1) tokenBalance.migrationIndex++;
            _updateToVaultPending(retiringVaultKey, ChainType.NATIVE, _chain, token, migrationAmount,  true);

            return (false, token, migrationAmount - gasInfo.estimateGas);
        }

        // todo: emit event
        return (true, token, 0);
    }


    function _collectVaultAndBalanceFee(bytes32 orderId, address token, uint256 amount, FeeInfo memory feeInfo) internal returns (uint256 outAmount) {
        uint256 balanceFee = feeInfo.balanceFee;
        if (feeInfo.vaultFee > 0) {
            // todo: check vault token exist
            IVaultToken vaultToken = IVaultToken(tokenList.get(token));
            if(vaultToken.totalSupply() > 0) {
                vaultToken.increaseVault(feeInfo.vaultFee);
            } else {
                reservedFees[token] += feeInfo.vaultFee;
            }
        }

        if (feeInfo.incentive) {
            balanceFees[token] -= feeInfo.balanceFee;
            outAmount = amount + balanceFee - feeInfo.vaultFee;
        } else {
            balanceFees[token] += feeInfo.balanceFee;
            outAmount = amount - feeInfo.balanceFee - feeInfo.vaultFee;
        }

        emit FeeCollected(orderId, token, feeInfo.vaultFee, feeInfo.ammFee, balanceFee, feeInfo.incentive);
    }

    function _collectFee(bytes32 orderId, uint256 fromChain, uint256 toChain, address token, uint256 amount, bool isSwapIn, bool isSwapOut) internal returns (uint256) {
        FeeInfo memory feeInfo;

        (feeInfo.incentive, feeInfo.balanceFee) = _getBalanceFee(fromChain, toChain, token, amount, isSwapIn, isSwapOut);
        if (!feeInfo.incentive) {
            // will not collect vault fee when rebalance incentive
            if (isSwapIn) {
                feeInfo.vaultFee = _getFee(amount, vaultFeeRate.fromVault);
            } else if (isSwapOut) {
                feeInfo.vaultFee = _getFee(amount, vaultFeeRate.toVault);
            } else {
                // feeInfo.ammFee = _getFee(amount, vaultFeeRate.ammVault);
                feeInfo.vaultFee = _getFee(amount, vaultFeeRate.fromVault + vaultFeeRate.toVault);
            }
        }

        return _collectVaultAndBalanceFee(orderId, token,amount, feeInfo);
    }

    // add token balance
    // add from chain and token vault
    function _updateFromVault(bytes32 vaultKey, TxItem calldata txItem, bool isMigration) internal {
        vaultList[vaultKey].chains.add(txItem.chain);

        uint128 amount = uint128(txItem.amount);

        // todo: check token mintable, mintable token not add from vault balance
        tokenStates[txItem.token].balance += amount;
        tokenStates[txItem.token].chainStates[txItem.chain].balance += int128(amount);

        if (!isMigration) {
            // update relay chain balance for token mint
            tokenStates[txItem.token].chainStates[selfChainId].balance -= int128(amount);
        }

        if (txItem.chainType != ChainType.CONTRACT) {
            _addVaultToken(vaultKey, txItem.chain, txItem.token);
            vaultList[vaultKey].chainVaults[txItem.chain].tokenVaults[txItem.token].balance += amount;
        }
    }

    // update target vault pending amount, include gas info
    function _updateToVaultPending(bytes32 vaultKey, ChainType chainType, uint256 chain, address token, uint128 totalOutAmount, bool isMigration) internal {
        // todo: support alt chain on non-contract chain

        // todo: check mintable
        tokenStates[token].pendingOut += totalOutAmount;
        tokenStates[token].chainStates[chain].pendingOut += totalOutAmount;

        if (chainType != ChainType.CONTRACT) {
            vaultList[vaultKey].chainVaults[chain].tokenVaults[token].pendingOut += totalOutAmount;
        }

        if (selfChainId != chain && !isMigration) {
            // will burn relay token after transfer complete
            tokenStates[token].chainStates[selfChainId].pendingOut += totalOutAmount;
        }
    }

    // update target vault balance, remove pending
    function _updateToVaultComplete(bytes32 vaultKey, TxItem calldata txItem, uint128 usedGas, uint128 estimateGas, bool isMigration) internal {
        TokenState storage totalState = tokenStates[txItem.token];
        TokenChainState storage chainState = tokenStates[txItem.token].chainStates[txItem.chain];

        uint128 amount = uint128(txItem.amount);

        if (txItem.chainType == ChainType.CONTRACT) {
            // todo: check mintable
            if(txItem.chain != selfChainId) {
                totalState.balance -= amount;
                chainState.balance -= int128(amount);
            }
            totalState.pendingOut -= amount;
            chainState.pendingOut -= amount;

            if(txItem.chain != selfChainId && !isMigration) {
                tokenStates[txItem.token].chainStates[selfChainId].pendingOut -= amount;
                tokenStates[txItem.token].chainStates[selfChainId].balance += int128(amount);
            }

            return;
        }
        // add tx gas cost for non contract chain
        ChainTokenVault storage tokenVault = vaultList[vaultKey].chainVaults[txItem.chain].tokenVaults[txItem.token];
        // todo: support alt token
        //       update gas token balance with usedGas
        //       update alt token balance with amount
        uint128 totalOutAmount = amount + usedGas;
        uint128 totalPendingOut = amount + estimateGas;

        if(txItem.chain != selfChainId) {
            totalState.balance -= totalOutAmount;
        }

        totalState.pendingOut -= totalPendingOut;

        chainState.balance -= int128(totalOutAmount);
        chainState.pendingOut -= totalPendingOut;

        tokenVault.balance -= totalOutAmount;
        tokenVault.pendingOut -= totalPendingOut;
        if(txItem.chain != selfChainId && !isMigration) {
            tokenStates[txItem.token].chainStates[selfChainId].pendingOut -= totalPendingOut;
            tokenStates[txItem.token].chainStates[selfChainId].balance += int128(totalOutAmount);
        }
    }


    // S_max represents the worst possible imbalance scenario where all assets are concentrated on a single chain.
    // It serves as the upper bound for normalization.
    //
    // For a given weight distribution, S_max occurs when:
    //- One chain k has all assets: Vₖ = Vₜ (thus rₖ = 1/Wₖ - 1)
    //- All other chains are empty: Vᵢ = 0 for i ≠ k (thus rᵢ = -1)
    // Wₜ = 1, S_k = (1 - Wₖ)/Wₖ
    function _updateBalanceIndicator(address _token) internal {
        uint32 minWeight = type(uint32).max;
        uint256 length = chainList.length();

        TokenState storage tokenState = tokenStates[_token];
        for (uint256 i = 0; i < length; i++) {
            uint256 chain = chainList.at(i);
            uint32 w = tokenState.chainStates[chain].weight;
            if (w == 0) {
                continue;
            }
            if (w < minWeight) {
                minWeight = w;
            }
        }

        tokenState.deltaSMax = (tokenState.totalWeight - minWeight) / minWeight;

        emit UpdateBalanceIndicator(_token, tokenState.totalWeight, tokenState.deltaSMax);
    }


    // ------------------------------------------- internal view ----------------------------------------------

    function _chooseVault(TxItem memory txItem, bool withCall)
    internal
    view
    returns (bytes32 vaultKey, uint256 outAmount, uint256 totalOutAmount, GasInfo memory gasInfo)
    {
        if(txItem.chain == selfChainId) {
            return (activeVaultKey, txItem.amount, txItem.amount, gasInfo);
        }
        // todo: support alt token on non-contract chain
        //      get gas for gas token
        gasInfo = registry.getNetworkFeeInfoWithToken(txItem.token, txItem.chain,withCall);
        txItem.amount = _truncation(txItem.amount);
        uint256 minAmount = gasInfo.estimateGas + _getRelayOutMinAmount(txItem.token, txItem.chain);
        if (txItem.amount <= minAmount) {
            return (NON_VAULT_KEY, 0, 0, gasInfo);
        }

        outAmount = txItem.amount - gasInfo.estimateGas;

        uint128 allowance;
        if (txItem.chainType == ChainType.CONTRACT) {
            // todo: check mintable
//            bool mintable = periphery.isTokenMintable(txItem.chain, txItem.token);
//            if (mintable) {
//                // mintable token, no need check vault
//                return (activeVaultKey, outAmount, gasInfo);
//            }
            TokenChainState storage chainState = tokenStates[txItem.token].chainStates[txItem.chain];
            // if(chainState.balance < 0) return (NON_VAULT_KEY, txItem.amount, gasInfo);

            allowance = uint128(chainState.balance) - chainState.pendingOut;
            if (allowance < outAmount) return (NON_VAULT_KEY, 0, 0, gasInfo);

            vaultKey = (vaultList[activeVaultKey].chains.contains(txItem.chain)) ? activeVaultKey : retiringVaultKey;
            totalOutAmount = outAmount;
        } else {
            // non-contract chain
            // choose active vault first, if not match, choose retiring vault
            if (_checkVaultAllowance(activeVaultKey, txItem)) {
                vaultKey = activeVaultKey;
            } else if (_checkVaultAllowance(retiringVaultKey, txItem)) {
                vaultKey = retiringVaultKey;
            } else {
                return (NON_VAULT_KEY, 0, 0, gasInfo);
            }
            totalOutAmount = txItem.amount;
        }

        return (vaultKey, outAmount, totalOutAmount, gasInfo);
    }

    function _checkVaultAllowance(bytes32 vaultKey, TxItem memory txItem) internal view returns (bool) {
        ChainTokenVault storage p = vaultList[vaultKey].chainVaults[txItem.chain].tokenVaults[txItem.token];
        uint128 allowance = p.balance - p.pendingOut;
        return (allowance >= txItem.amount);
    }


    function _getBalanceFee(uint256 fromChain, uint256 toChain, address token, uint256 amount, bool isSwapIn, bool isSwapOut)
    internal
    view
    returns (bool incentive, uint256 fee)
    {   
        if(fromChain == toChain) return (false, 0);
        Rebalance.BalanceInfo memory info;
        info.a = int256(amount);
        info.vt = int256(int128(tokenStates[token].balance));
        info.wt = int256(int32(tokenStates[token].totalWeight));

        info.wx = int256(int32(tokenStates[token].chainStates[fromChain].weight));
        info.wy = int256(int32(tokenStates[token].chainStates[toChain].weight));
        info.vx = int256(int128(tokenStates[token].chainStates[fromChain].balance));
        info.vy = int256(int128(tokenStates[token].chainStates[toChain].balance));

        int32 rate = Rebalance.getBalanceFeeRate(info, balanceFeeRate, int32(tokenStates[token].deltaSMax), isSwapIn, isSwapOut);

        incentive = (rate < 0);
        uint256 feeRate = incentive ? uint256(int256(-rate)) : uint256(int256(rate));
        fee = _getFee(amount, feeRate);

        if(incentive) {
            // max incentive is balance fee
            uint256 maxIncentive = balanceFees[token];
            if(fee > maxIncentive) {
                fee = maxIncentive;
            }
        }
    }


    function _getRelayOutMinAmount(address token, uint256 toChain) internal view returns (uint128) {
        return tokenStates[token].chainStates[toChain].minAmount;
    }


    function _getFee(uint256 amount, uint256 feeRate) internal pure returns (uint256 fee) {
        if (feeRate == 0) {
            return 0;
        }
        fee = amount * feeRate / MAX_RATE_UNIT;
    }

    function _truncation(uint256 amount) internal pure returns(uint256) {
        return _adjustDecimals(_adjustDecimals(amount, 6, 18), 18, 6);
    }

    function _adjustDecimals(uint256 amount, uint256 decimalsMul, uint256 decimalsDiv) internal pure returns(uint256) {
        return amount * 10 ** decimalsMul / (10 ** decimalsDiv);
    }
}
