// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./libs/Utils.sol";
import "./interfaces/IVaultToken.sol";
import "./interfaces/IRegistry.sol";

import {IVaultManager} from "./interfaces/IVaultManager.sol";

import {ChainType, TxItem} from "./libs/Types.sol";
import {Errs} from "./libs/Errors.sol";

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {BaseImplementation} from "@mapprotocol/common-contracts/contracts/base/BaseImplementation.sol";
import {IPeriphery} from "./interfaces/IPeriphery.sol";

contract VaultManager is BaseImplementation, IVaultManager {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 private constant MAX_MIGRATION_AMOUNT = 3;

    // for contract chain
    // migration don't include the migration token number, so how to update balance for new vault
    // if keep a unique balance, how to check should use the old or new vault
    struct ChainAllowance {
        bool migrationPending; // set true after start a migration, reset after migration txOut on relay chain.
        // used by non-contract chain
        uint8 migrationIndex;
        uint256 tokenAllowances;
        uint256 tokenPendingOutAllowances;
    }

    struct Vault {
        EnumerableSet.UintSet chains;
        bytes pubkey;
        mapping(uint256 => ChainAllowance) chainAllowances;
    }

    // only one active vault and one retiring vault at a time
    bytes32 public activeVaultKey;
    bytes32 public retiringVaultKey;

    mapping(bytes32 => Vault) vaultList;

    EnumerableMap.AddressToAddressMap tokenList;
    EnumerableSet.UintSet chainList;

    address public relay;

    IPeriphery public periphery;

    // for rebalancing calculation
    // token => totalWeight
    mapping(address => uint256) tokenTotalWeights;
    // token => chain => weight
    mapping(address => mapping(uint256 => uint256)) tokenChainWeights;
    // token => totalAllowance
    mapping(address => uint256) tokenTotalAllowance;

    // token => chain => targetBalance
    mapping(address => mapping(uint256 => uint256)) tokenTargetBalances;

    // token => chain => allowance
    mapping(address => mapping(uint256 => uint256)) tokenAllowances;
    mapping(address => mapping(uint256 => uint256)) tokenPendingOutAllowances;

    modifier onlyRelay() {
        if (msg.sender != address(relay)) revert Errs.no_access();
        _;
    }

    function rotate(bytes memory retiringVault, bytes memory activeVault) external override onlyRelay {
        activeVaultKey = keccak256(activeVault);
        retiringVaultKey = keccak256(retiringVault);
        vaultList[activeVaultKey].pubkey = activeVault;
    }

    function addChain(uint256 chain) external override onlyRelay {
        vaultList[activeVaultKey].chains.add(chain);
    }

    function removeChain(uint256 chain) external override onlyRelay {
        if (periphery.getChainType(chain) != ChainType.CONTRACT) {
            if(vaultList[activeVaultKey].chainAllowances[chain].tokenAllowances > 0) {
                revert Errs.token_allowance_not_zero();
            }
        }
        vaultList[activeVaultKey].chains.remove(chain);
    }

    function checkMigration() external override onlyRelay returns (bool completed, uint256 toMigrateChain) {
        // check the retiring vault first
        if (retiringVaultKey == bytes32(0x00)) {
            return (true, 0);
        }

        Vault storage v = vaultList[retiringVaultKey];
        uint256[] memory chains = v.chains.values();
        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chain = chains[i];
            if (v.chainAllowances[chain].migrationPending) {
                // migrating, continue to other chain migration
                continue;
            }

            return (false, chain);
        }

        if (v.chains.length() > 0) {
            return (false, 0);
        }
        // retiring vault migration completed
        // return and wait update tss vault status
        retiringVaultKey = bytes32(0x00);
        return (true, 0);
    }

    function migrate(uint256 _chain, uint256 fee)
        external
        onlyRelay
        returns (bool toMigrate, bytes memory fromVault, bytes memory toVault, uint256 migrationAmount)
    {
        if (periphery.getChainType(_chain) == ChainType.CONTRACT) {
            // token allowances managed by a global allowance
            // switch to active vault after migration when choosing vault
            vaultList[retiringVaultKey].chainAllowances[_chain].migrationPending = true;

            vaultList[activeVaultKey].chains.add(_chain);
            return (true, vaultList[retiringVaultKey].pubkey, vaultList[activeVaultKey].pubkey, 0);
        }

        ChainAllowance storage p = vaultList[retiringVaultKey].chainAllowances[_chain];
        uint256 amount = p.tokenAllowances - p.tokenPendingOutAllowances;
        // todo: add min amount
        if (amount <= fee) {
            if (p.tokenPendingOutAllowances > 0) {
                return (false, fromVault, toVault, 0);
            }
            // no need migration
            vaultList[retiringVaultKey].chains.remove(_chain);
            delete vaultList[retiringVaultKey].chainAllowances[_chain];

            return (false, fromVault, toVault, 0);
        }

        vaultList[retiringVaultKey].chainAllowances[_chain].migrationPending = true;

        migrationAmount = amount / (MAX_MIGRATION_AMOUNT - p.migrationIndex);
        if (migrationAmount <= fee || (amount - migrationAmount) <= fee) {
            migrationAmount = amount;
        }
        p.migrationIndex++;

        p.tokenPendingOutAllowances += (migrationAmount + fee);

        return (true, vaultList[retiringVaultKey].pubkey, vaultList[activeVaultKey].pubkey, migrationAmount);
    }

    function chooseVault(uint256 chain, address token, uint256 amount, uint256 gas)
        external
        view
        onlyRelay
        returns (bytes memory vault)
    {   
        uint256 allowance;
        if (periphery.getChainType(chain) == ChainType.CONTRACT) {
            allowance = tokenAllowances[token][chain] - tokenPendingOutAllowances[token][chain];
            if(allowance < amount) return bytes("");
            if (vaultList[activeVaultKey].chains.contains(chain)) {
                return vaultList[activeVaultKey].pubkey;
            } else {
                return vaultList[retiringVaultKey].pubkey;
            }
        }
        // non-contract chain
        // choose active vault first, if not match, choose retiring vault
        ChainAllowance storage p = vaultList[activeVaultKey].chainAllowances[chain];
        allowance = p.tokenAllowances - p.tokenPendingOutAllowances;
        if (allowance >= amount + gas) {
            return vaultList[activeVaultKey].pubkey;
        }

        p = vaultList[retiringVaultKey].chainAllowances[chain];
        allowance = p.tokenAllowances - p.tokenPendingOutAllowances;
        if (allowance >= amount + gas) {
            return vaultList[retiringVaultKey].pubkey;
        }

        return bytes("");
    }

    function migrationOut(TxItem memory txItem, bytes memory toVault, uint256 estimatedGas, uint256 usedGas)
        external
        override
        onlyRelay
    {
        bytes32 vaultKey = keccak256(txItem.vault);
        bytes32 targetVaultKey = keccak256(toVault);
        if (vaultKey != retiringVaultKey || targetVaultKey != activeVaultKey) revert Errs.invalid_vault();

        if (periphery.getChainType(txItem.chain) == ChainType.CONTRACT) {
            delete vaultList[vaultKey].chainAllowances[txItem.chain];
            vaultList[vaultKey].chains.remove(txItem.chain);
        } else {
            ChainAllowance storage p = vaultList[vaultKey].chainAllowances[txItem.chain];
            p.migrationPending = false;

            p.tokenAllowances -= (txItem.amount + usedGas);
            p.tokenPendingOutAllowances -= (txItem.amount + estimatedGas);

            vaultList[targetVaultKey].chains.add(txItem.chain);
            vaultList[targetVaultKey].chainAllowances[txItem.chain].tokenAllowances += txItem.amount;

            tokenTotalAllowance[txItem.token] -= usedGas;
            tokenAllowances[txItem.token][txItem.chain] -= usedGas;
        }
    }

    function deposit(uint256 chain, bytes32 vaultKey, address token, uint256 amount) external onlyRelay {
        // todo: update target allowance
    }

    function withdraw(uint256 chain, bytes32 vaultKey, address token, uint256 amount) external onlyRelay {
        // todo: update target allowance
    }

    // tx in, add liquidity or swap in
    function transferIn(uint256 fromChain, bytes memory vault, address token, uint256 amount)
        external
        onlyRelay
        returns (bool)
    {
        bytes32 vaultKey = keccak256(vault);

        if (vaultKey != activeVaultKey && vaultKey != retiringVaultKey) {
            return false;
        }

        tokenTotalAllowance[token] += amount;
        tokenAllowances[token][fromChain] += amount;

        if (periphery.getChainType(fromChain) == ChainType.CONTRACT) {
            // todo: add chain to active vault ?
            return true;
        }

        vaultList[vaultKey].chains.add(fromChain);
        vaultList[vaultKey].chainAllowances[fromChain].tokenAllowances += amount;

        return true;
    }

    // tx out, remove liquidity or swap out
    function transferOut(uint256 chain, bytes memory vault, address token, uint256 amount, uint256 relayGasUsed, uint256 relayGasEstimated)
        external
        override
        onlyRelay
    {
        bytes32 vaultKey = keccak256(vault);

        if (vaultKey != retiringVaultKey || vaultKey != activeVaultKey) revert Errs.invalid_vault();

        tokenTotalAllowance[token] -= amount;
        tokenAllowances[token][chain] -= amount;
        tokenPendingOutAllowances[token][chain] -= (amount + relayGasEstimated);

        if (periphery.getChainType(chain) != ChainType.CONTRACT) {
            tokenTotalAllowance[token] -= relayGasUsed;
            tokenAllowances[token][chain] -= relayGasUsed;
            
            vaultList[vaultKey].chainAllowances[chain].tokenAllowances -= (amount + relayGasUsed);
            vaultList[vaultKey].chainAllowances[chain].tokenPendingOutAllowances -= (amount + relayGasEstimated);
        }
    }


    // bridge
    function doTransfer(uint256 toChain, bytes memory vault, address token, uint256 amount, uint256 estimatedGas)
        external
        override
        onlyRelay
    {
        // todo: calculate balance fee

        bytes32 vaultKey = keccak256(vault);

        if (vaultKey != activeVaultKey && vaultKey != retiringVaultKey) {
            return;
        }

        if (periphery.getChainType(toChain) == ChainType.CONTRACT) {
            tokenPendingOutAllowances[token][toChain] += amount;

            return;
        }

        tokenPendingOutAllowances[token][toChain] += (amount + estimatedGas);

        vaultList[vaultKey].chains.add(toChain);
        vaultList[vaultKey].chainAllowances[toChain].tokenPendingOutAllowances += (amount + estimatedGas);
    }

    function checkVault(bytes calldata vault) external view returns(bool) {
        bytes32 vaultKey = keccak256(vault);
        return (vaultKey == retiringVaultKey || vaultKey == activeVaultKey);
    }

    function updateVault(uint256 fromChain, uint256 toChain, address token, uint256 amount) external override {
        
    }

    function getBalanceFee(uint256 fromChain, uint256 toChain, address token, uint256 amount)
        external
        view
        override
        returns (uint256, bool)
    {

    }

}
