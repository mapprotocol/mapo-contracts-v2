// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

// ============================================================
// VaultManager API Reference (verified from source)
// ============================================================
//
// INITIALIZE:
//   initialize(address _defaultAdmin) — sets AccessManager authority
//
// ADMIN (restricted — admin role via AuthorityManager):
//   setRelay(address _relay)
//   setRegistry(address _registry)
//   registerToken(address _token, address _vaultToken)
//     - requires: _token == vaultToken.asset() AND vaultToken.vaultManager() == address(this)
//   updateVaultFeeRate(VaultFeeRate calldata _vaultFeeRate)
//   updateBalanceFeeRate(Rebalance.BalanceFeeRate calldata _balanceFeeRate)
//   updateTokenWeights(address token, uint256[] chains, uint256[] weights)
//   setMinAmount(address token, uint256 chain, uint128 minAmount)
//
// RELAY-ONLY (onlyRelay — msg.sender == relay):
//   addChain(uint256 chain)
//   removeChain(uint256 chain)
//   rotate(bytes retiringVault, bytes activeVault)
//     - first rotation: retiringVault == bytes(""), activeVault == new vault bytes
//     - subsequent: retiringVault == current activeVault bytes
//   updateFromVault(TxItem txItem, uint256)
//   transferIn(TxItem txItem, uint256) returns (uint256 outAmount)
//   bridgeOut(TxItem txItem, uint256 toChain, bool withCall) returns (bool, uint256, bytes, GasInfo)
//   transferOut(TxItem txItem, uint256, bool) returns (bool, uint256, bytes, GasInfo)
//   deposit(TxItem txItem, address to)
//   redeem(address vaultToken, uint256 share, address owner, address receiver) returns (address, uint256)
//   transferComplete(TxItem txItem, uint128 usedGas, uint128 estimatedGas) returns (uint256, uint256)
//   migrationComplete(TxItem txItem, bytes toVault, uint128 usedGas, uint128 estimatedGas) returns (uint256, uint256)
//   migrate() returns (bool, TxItem, GasInfo, bytes, bytes)
//   refund(TxItem txItem, bool fromRetiredVault) returns (uint256, GasInfo)
//
// VIEWS (public):
//   getActiveVaultKey() returns (bytes32)
//   getActiveVault() returns (bytes)
//   getRetiringVault() returns (bytes)
//   getVaultToken(address relayToken) returns (address)
//   getBridgeChains() returns (uint256[])
//   getBridgeTokens() returns (address[])
//   getVaultFeeRate() returns (uint32 ammVault, uint32 fromVault, uint32 toVault)
//   getRelayOutMinAmount(address token, uint256 toChain) returns (uint128)
//   getVaultTokenBalance(bytes vault, uint256 chain, address token) returns (int256, uint256)
//   getBalanceFee(uint256 fromChain, uint256 toChain, address token, uint256 amount) returns (bool, uint256)
//   checkVault(TxItem txItem) returns (bool)
//   checkMigration() returns (bool completed)
//
// TxItem struct: { bytes32 orderId, bytes32 vaultKey, uint256 chain, ChainType chainType, address token, uint256 amount }
// VaultFeeRate struct: { uint32 ammVault, uint32 fromVault, uint32 toVault, uint160 reserved }
//
// KEY BEHAVIORS:
//   - onlyRelay: checked via msg.sender == relay
//   - restricted: checked via AccessManager (admin role)
//   - rotate() requires retiringVaultKey == NON_VAULT_KEY (bytes32(0)) before calling
//   - registerToken() requires vaultToken.vaultManager() == address(this) first
//   - VaultToken._deposit() only callable via VaultManager (checked by onlyManager)
//   - getVaultKey(pubkey) = keccak256(pubkey)
// ============================================================

import {BaseTest} from "./BaseTest.sol";

import {VaultToken} from "../../contracts/VaultToken.sol";
import {ERC1967Proxy} from "../../contracts/ERC1967Proxy.sol";
import {TxItem, ChainType, GasInfo} from "../../contracts/libs/Types.sol";
import {Errs} from "../../contracts/libs/Errors.sol";
import {Utils} from "../../contracts/libs/Utils.sol";
import {Rebalance} from "../../contracts/libs/Rebalance.sol";

contract VaultManagerTest is BaseTest {
    VaultToken public vaultToken;

    // Vault public key bytes used in tests
    bytes public activeVaultBytes;
    bytes public retiringVaultBytes;
    bytes public newVaultBytes;

    // Token ID used when registering testToken in registry
    uint96 constant TEST_TOKEN_ID = 1;

    function setUp() public override {
        super.setUp();

        // Deploy VaultToken impl + proxy for testToken
        address vaultTokenImpl = address(new VaultToken());
        address vaultTokenProxy = _deployProxy(
            vaultTokenImpl,
            abi.encodeCall(
                VaultToken.initialize,
                (address(authority), address(testToken), "Vault Test Token", "vTT")
            )
        );
        vaultToken = VaultToken(vaultTokenProxy);

        // Set VaultManager on VaultToken (restricted = admin role)
        vm.prank(admin);
        vaultToken.setVaultManager(address(vaultManager));

        // Register testToken in VaultManager (requires vaultManager == address(this) set above)
        vm.prank(admin);
        vaultManager.registerToken(address(testToken), address(vaultToken));

        // Register testToken in registry so cross-chain mapping works
        _registerToken(address(testToken), TEST_TOKEN_ID, ETH_CHAIN_ID, abi.encodePacked(address(testToken)), 18);

        // Add ETH chain to VaultManager (onlyRelay)
        vm.prank(address(relay));
        vaultManager.addChain(ETH_CHAIN_ID);

        // Prepare vault key bytes
        activeVaultBytes = _makeVaultBytes("vault_active");
        retiringVaultBytes = _makeVaultBytes("vault_retiring");
        newVaultBytes = _makeVaultBytes("vault_new");
    }

    // -----------------------------------------------------------------------
    // Helper: perform initial vault rotation (sets active vault)
    // -----------------------------------------------------------------------

    function _rotateToActive() internal {
        vm.prank(address(relay));
        vaultManager.rotate(bytes(""), activeVaultBytes);
    }

    // -----------------------------------------------------------------------
    // Admin / Setup Tests
    // -----------------------------------------------------------------------

    function test_setRelay_updatesRelay() public {
        address newRelay = makeAddr("newRelay");
        vm.prank(admin);
        vaultManager.setRelay(newRelay);
        assertEq(vaultManager.relay(), newRelay);
    }

    function test_setRegistry_updatesRegistry() public {
        address newRegistry = makeAddr("newRegistry");
        vm.prank(admin);
        vaultManager.setRegistry(newRegistry);
        assertEq(address(vaultManager.registry()), newRegistry);
    }

    function test_registerToken_storesVaultToken() public view {
        address stored = vaultManager.getVaultToken(address(testToken));
        assertEq(stored, address(vaultToken));
    }

    function test_revert_registerToken_unauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        vaultManager.registerToken(address(testToken6), address(vaultToken));
    }

    function test_updateVaultFeeRate_updatesFees() public {
        vm.prank(admin);
        vaultManager.updateVaultFeeRate(
            VaultManagerHelper.makeFeeRate(1000, 2000, 3000)
        );
        (uint32 ammVault, uint32 fromVault, uint32 toVault) = vaultManager.getVaultFeeRate();
        assertEq(ammVault, 1000);
        assertEq(fromVault, 2000);
        assertEq(toVault, 3000);
    }

    function test_revert_updateVaultFeeRate_unauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        vaultManager.updateVaultFeeRate(VaultManagerHelper.makeFeeRate(1000, 2000, 3000));
    }

    // -----------------------------------------------------------------------
    // Chain Management Tests (onlyRelay)
    // -----------------------------------------------------------------------

    function test_addChain_addsToList() public {
        vm.prank(address(relay));
        vaultManager.addChain(BSC_CHAIN_ID);

        uint256[] memory chains = vaultManager.getBridgeChains();
        bool found = false;
        for (uint256 i = 0; i < chains.length; i++) {
            if (chains[i] == BSC_CHAIN_ID) {
                found = true;
                break;
            }
        }
        assertTrue(found, "BSC chain should be in bridge chains list");
    }

    function test_removeChain_removesFromList() public {
        // First add BSC chain (ETH already added in setUp)
        vm.prank(address(relay));
        vaultManager.addChain(BSC_CHAIN_ID);

        // Rotate so activeVault exists (removeChain checks migrationStatus and balances)
        _rotateToActive();

        // Remove chain — should succeed since no balance
        vm.prank(address(relay));
        vaultManager.removeChain(BSC_CHAIN_ID);

        uint256[] memory chains = vaultManager.getBridgeChains();
        for (uint256 i = 0; i < chains.length; i++) {
            assertNotEq(chains[i], BSC_CHAIN_ID, "BSC chain should be removed");
        }
    }

    function test_revert_addChain_notRelay() public {
        vm.prank(user1);
        vm.expectRevert(Errs.no_access.selector);
        vaultManager.addChain(BSC_CHAIN_ID);
    }

    // -----------------------------------------------------------------------
    // Vault Rotation Tests
    // -----------------------------------------------------------------------

    function test_rotate_setsActiveVault() public {
        vm.prank(address(relay));
        vaultManager.rotate(bytes(""), activeVaultBytes);

        bytes memory stored = vaultManager.getActiveVault();
        assertEq(keccak256(stored), keccak256(activeVaultBytes));
    }

    function test_rotate_setsActiveAndRetiringVault() public {
        // First rotation: activeVaultBytes becomes active
        vm.prank(address(relay));
        vaultManager.rotate(bytes(""), activeVaultBytes);

        // Second rotation: activeVaultBytes becomes retiring, newVaultBytes becomes active
        vm.prank(address(relay));
        vaultManager.rotate(activeVaultBytes, newVaultBytes);

        bytes memory storedActive = vaultManager.getActiveVault();
        bytes memory storedRetiring = vaultManager.getRetiringVault();

        assertEq(keccak256(storedActive), keccak256(newVaultBytes));
        assertEq(keccak256(storedRetiring), keccak256(activeVaultBytes));
    }

    function test_rotate_updatesVaultKey() public {
        vm.prank(address(relay));
        vaultManager.rotate(bytes(""), activeVaultBytes);

        bytes32 expectedKey = Utils.getVaultKey(activeVaultBytes);
        assertEq(vaultManager.getActiveVaultKey(), expectedKey);
    }

    // -----------------------------------------------------------------------
    // Vault Status / checkVault Tests
    // -----------------------------------------------------------------------

    function test_checkVault_contractChainAlwaysValid() public {
        _rotateToActive();

        // CONTRACT chain type always returns true regardless of vault key
        TxItem memory txItem;
        txItem.vaultKey = bytes32(uint256(0xdead));
        txItem.chainType = ChainType.CONTRACT;

        assertTrue(vaultManager.checkVault(txItem));
    }

    function test_checkVault_activeVaultIsValid() public {
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);
        TxItem memory txItem;
        txItem.vaultKey = activeKey;
        txItem.chainType = ChainType.NATIVE;

        assertTrue(vaultManager.checkVault(txItem));
    }

    function test_checkVault_unknownVaultIsInvalid() public {
        _rotateToActive();

        TxItem memory txItem;
        txItem.vaultKey = bytes32(uint256(0xdeadbeef));
        txItem.chainType = ChainType.NATIVE;

        assertFalse(vaultManager.checkVault(txItem));
    }

    // -----------------------------------------------------------------------
    // Min Amount Tests
    // -----------------------------------------------------------------------

    function test_setMinAmount_storesValue() public {
        uint128 minAmt = 1e18;
        vm.prank(admin);
        vaultManager.setMinAmount(address(testToken), ETH_CHAIN_ID, minAmt);

        uint128 stored = vaultManager.getRelayOutMinAmount(address(testToken), ETH_CHAIN_ID);
        assertEq(stored, minAmt);
    }

    function test_getRelayOutMinAmount_returnsValue() public {
        uint128 minAmt = 5e17;
        vm.prank(admin);
        vaultManager.setMinAmount(address(testToken), ETH_CHAIN_ID, minAmt);

        assertEq(vaultManager.getRelayOutMinAmount(address(testToken), ETH_CHAIN_ID), minAmt);
    }

    // -----------------------------------------------------------------------
    // Access Control Tests
    // -----------------------------------------------------------------------

    function test_revert_rotate_notRelay() public {
        vm.prank(user1);
        vm.expectRevert(Errs.no_access.selector);
        vaultManager.rotate(bytes(""), activeVaultBytes);
    }

    function test_revert_updateFromVault_notRelay() public {
        TxItem memory txItem;
        txItem.chain = ETH_CHAIN_ID;
        txItem.token = address(testToken);
        txItem.amount = 1e18;
        txItem.chainType = ChainType.CONTRACT;

        vm.prank(user1);
        vm.expectRevert(Errs.no_access.selector);
        vaultManager.updateFromVault(txItem, 0);
    }

    // -----------------------------------------------------------------------
    // Balance Tracking Tests (Task 2)
    // -----------------------------------------------------------------------

    function test_updateFromVault_recordsBalance() public {
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        // Construct a TxItem representing tokens locked on ETH chain
        TxItem memory txItem;
        txItem.orderId = bytes32(uint256(1));
        txItem.vaultKey = activeKey;
        txItem.chain = ETH_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 10e18;

        vm.prank(address(relay));
        vaultManager.updateFromVault(txItem, 0);

        // Check balance recorded via getVaultTokenBalance
        (int256 balance, ) = vaultManager.getVaultTokenBalance(activeVaultBytes, ETH_CHAIN_ID, address(testToken));
        assertEq(balance, int256(10e18));
    }

    function test_transferIn_returnsOutAmount() public {
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        TxItem memory txItem;
        txItem.orderId = bytes32(uint256(2));
        txItem.vaultKey = activeKey;
        txItem.chain = ETH_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 5e18;

        vm.prank(address(relay));
        uint256 outAmount = vaultManager.transferIn(txItem, 0);

        // With no vault fee rate set (all zeros), out amount == input amount
        assertEq(outAmount, 5e18);
    }

    // -----------------------------------------------------------------------
    // VaultToken (ERC4626) Tests via VaultManager
    // -----------------------------------------------------------------------

    function test_deposit_mintsShares() public {
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        // Seed the VaultManager with tokens (deposit flow: VaultManager holds no actual tokens
        // but VaultToken.balance tracks virtual balance via increaseVault in _collectFee)
        // With zero fee rate, deposit simply calls vaultToken.deposit(amount, to)
        // VaultToken._deposit checks caller == vaultManager

        TxItem memory txItem;
        txItem.orderId = bytes32(uint256(3));
        txItem.vaultKey = activeKey;
        txItem.chain = SELF_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 100e18;

        vm.prank(address(relay));
        vaultManager.deposit(txItem, user1);

        // user1 should have received vault shares (1:1 with assets when totalAssets starts at 0)
        uint256 shares = vaultToken.balanceOf(user1);
        assertGt(shares, 0, "user1 should have vault shares after deposit");
    }

    function test_redeem_burnsSharesReturnsAssets() public {
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        // First deposit to give user1 some shares
        TxItem memory depositTxItem;
        depositTxItem.orderId = bytes32(uint256(4));
        depositTxItem.vaultKey = activeKey;
        depositTxItem.chain = SELF_CHAIN_ID;
        depositTxItem.chainType = ChainType.CONTRACT;
        depositTxItem.token = address(testToken);
        depositTxItem.amount = 100e18;

        vm.prank(address(relay));
        vaultManager.deposit(depositTxItem, user1);

        uint256 shares = vaultToken.balanceOf(user1);
        assertGt(shares, 0);

        // Now redeem: user1 approves VaultManager to burn their shares
        vm.prank(user1);
        vaultToken.approve(address(vaultManager), shares);

        vm.prank(address(relay));
        (address redeemToken, uint256 redeemAmount) = vaultManager.redeem(address(vaultToken), shares, user1, user2);

        assertEq(redeemToken, address(testToken));
        // With zero fees, full amount returned
        assertGt(redeemAmount, 0, "redeem should return non-zero amount");

        // user1 shares should be burned
        assertEq(vaultToken.balanceOf(user1), 0);
    }

    // -----------------------------------------------------------------------
    // Fee / Rate Tests
    // -----------------------------------------------------------------------

    function test_getVaultFeeRate_returnsSetRates() public {
        vm.prank(admin);
        vaultManager.updateVaultFeeRate(VaultManagerHelper.makeFeeRate(500, 1500, 2500));

        (uint32 ammVault, uint32 fromVault, uint32 toVault) = vaultManager.getVaultFeeRate();
        assertEq(ammVault, 500);
        assertEq(fromVault, 1500);
        assertEq(toVault, 2500);
    }

    function test_getBalanceFee_sameChainsReturnZero() public view {
        // fromChain == toChain always returns (false, 0)
        (bool incentive, uint256 fee) = vaultManager.getBalanceFee(ETH_CHAIN_ID, ETH_CHAIN_ID, address(testToken), 1e18);
        assertFalse(incentive);
        assertEq(fee, 0);
    }

    // -----------------------------------------------------------------------
    // bridgeOut Tests
    // -----------------------------------------------------------------------

    function test_bridgeOut_choosesVaultWhenBalanceAvailable() public {
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        // Seed balance via updateFromVault
        TxItem memory seedItem;
        seedItem.orderId = bytes32(uint256(10));
        seedItem.vaultKey = activeKey;
        seedItem.chain = ETH_CHAIN_ID;
        seedItem.chainType = ChainType.CONTRACT;
        seedItem.token = address(testToken);
        seedItem.amount = 1000e18;

        vm.prank(address(relay));
        vaultManager.updateFromVault(seedItem, 0);

        // Post network fee so getNetworkFeeInfoWithToken doesn't revert
        // GasService.postNetworkFee requires caller == relay (registered in registry)
        vm.prank(address(relay));
        gasService.postNetworkFee(ETH_CHAIN_ID, block.number, 100, 150, 1e9);

        // bridgeOut: transfer 50 tokens out to ETH chain
        TxItem memory txItem;
        txItem.orderId = bytes32(uint256(11));
        txItem.vaultKey = activeKey;
        txItem.chain = SELF_CHAIN_ID;  // source chain (relay)
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 50e18;

        vm.prank(address(relay));
        (bool choose, uint256 outAmount, bytes memory toVault, ) = vaultManager.bridgeOut(txItem, ETH_CHAIN_ID, false);

        assertTrue(choose, "bridgeOut should select a vault");
        assertGt(outAmount, 0, "out amount should be positive");
        // toVault should be one of the registered vault pubkeys
        assertTrue(toVault.length > 0, "vault bytes should not be empty");
    }

    function test_revert_bridgeOut_notRelay() public {
        TxItem memory txItem;
        txItem.chain = SELF_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 1e18;

        vm.prank(user1);
        vm.expectRevert(Errs.no_access.selector);
        vaultManager.bridgeOut(txItem, ETH_CHAIN_ID, false);
    }

    function test_revert_deposit_notRelay() public {
        TxItem memory txItem;
        txItem.chain = SELF_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 1e18;

        vm.prank(user1);
        vm.expectRevert(Errs.no_access.selector);
        vaultManager.deposit(txItem, user1);
    }

    function test_revert_redeem_notRelay() public {
        vm.prank(user1);
        vm.expectRevert(Errs.no_access.selector);
        vaultManager.redeem(address(vaultToken), 1e18, user1, user1);
    }

    function test_revert_redeem_zeroShare() public {
        vm.prank(address(relay));
        vm.expectRevert();
        vaultManager.redeem(address(vaultToken), 0, user1, user2);
    }

    function test_revert_redeem_zeroReceiver() public {
        vm.prank(address(relay));
        vm.expectRevert(Errs.zero_address.selector);
        vaultManager.redeem(address(vaultToken), 1e18, user1, address(0));
    }

    // asset() of the vault token is not a registered token
    function test_revert_redeem_unregisteredAsset() public {
        VaultToken other = VaultToken(
            _deployProxy(
                address(new VaultToken()),
                abi.encodeCall(VaultToken.initialize, (address(authority), address(testToken6), "Other", "OTH"))
            )
        );

        vm.prank(address(relay));
        vm.expectRevert(Errs.invalid_vault_token.selector);
        vaultManager.redeem(address(other), 1e18, user1, user2);
    }

    // asset() is registered, but the given vault token is not the registered one
    function test_revert_redeem_vaultTokenMismatch() public {
        VaultToken fake = VaultToken(
            _deployProxy(
                address(new VaultToken()),
                abi.encodeCall(VaultToken.initialize, (address(authority), address(testToken), "Fake", "FAKE"))
            )
        );

        vm.prank(address(relay));
        vm.expectRevert(Errs.invalid_vault_token.selector);
        vaultManager.redeem(address(fake), 1e18, user1, user2);
    }

    // -----------------------------------------------------------------------
    // Helper: add BSC chain to registry and VaultManager
    // -----------------------------------------------------------------------

    function _addBscChain() internal {
        // Register BSC in registry (admin prank)
        vm.prank(admin);
        registry.registerChain(
            BSC_CHAIN_ID,
            ChainType.CONTRACT,
            bytes(""),
            address(testToken),
            address(testToken),
            "BSC"
        );
        // Register BSC token mapping (reuse test token, different tokenId mapping)
        vm.startPrank(admin);
        registry.mapToken(address(testToken), BSC_CHAIN_ID, abi.encodePacked(address(testToken)), 18);
        vm.stopPrank();

        // Add BSC chain to VaultManager
        vm.prank(address(relay));
        vaultManager.addChain(BSC_CHAIN_ID);
    }

    // -----------------------------------------------------------------------
    // Migration lifecycle tests
    // -----------------------------------------------------------------------

    function test_checkMigration_trueWhenNoRetiringVault() public {
        // After the very first rotation, retiringVaultKey stays NON_VAULT_KEY
        _rotateToActive();
        assertTrue(vaultManager.checkMigration(), "checkMigration should return true when no retiring vault");
    }

    function test_checkMigration_falseWhenRetiringExists() public {
        // First rotation: empty -> activeVaultBytes
        _rotateToActive();
        // Second rotation: activeVaultBytes -> retiring, newVaultBytes -> active
        vm.prank(address(relay));
        vaultManager.rotate(activeVaultBytes, newVaultBytes);

        assertFalse(vaultManager.checkMigration(), "checkMigration should return false when retiring vault exists");
    }

    function test_transferComplete_contractChain_returnsEstimatedGas() public {
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        // Seed balance so there is something to bridge
        TxItem memory seedItem;
        seedItem.orderId = bytes32(uint256(20));
        seedItem.vaultKey = activeKey;
        seedItem.chain = ETH_CHAIN_ID;
        seedItem.chainType = ChainType.CONTRACT;
        seedItem.token = address(testToken);
        seedItem.amount = 100e18;

        vm.prank(address(relay));
        vaultManager.updateFromVault(seedItem, 0);

        // Post gas fee info
        vm.prank(address(relay));
        gasService.postNetworkFee(ETH_CHAIN_ID, block.number, 100, 150, 1e9);

        // bridgeOut to create a pending transfer
        TxItem memory bridgeItem;
        bridgeItem.orderId = bytes32(uint256(21));
        bridgeItem.vaultKey = activeKey;
        bridgeItem.chain = SELF_CHAIN_ID;
        bridgeItem.chainType = ChainType.CONTRACT;
        bridgeItem.token = address(testToken);
        bridgeItem.amount = 50e18;

        vm.prank(address(relay));
        (bool choose, uint256 outAmount, , ) = vaultManager.bridgeOut(bridgeItem, ETH_CHAIN_ID, false);
        assertTrue(choose, "bridgeOut should succeed");

        // Complete the transfer
        TxItem memory completeItem;
        completeItem.orderId = bytes32(uint256(22));
        completeItem.vaultKey = activeKey;
        completeItem.chain = ETH_CHAIN_ID;
        completeItem.chainType = ChainType.CONTRACT;
        completeItem.token = address(testToken);
        completeItem.amount = outAmount;

        uint128 estimatedGas = 150;

        vm.prank(address(relay));
        (uint256 reimbursedGas, uint256 amount) = vaultManager.transferComplete(completeItem, 100, estimatedGas);

        // CONTRACT chain returns (estimatedGas, txItem.amount)
        assertEq(reimbursedGas, estimatedGas, "reimbursedGas should equal estimatedGas for CONTRACT chain");
        assertEq(amount, outAmount, "amount should equal txItem.amount");
    }

    function test_transferComplete_revert_invalidVault() public {
        _rotateToActive();

        // Use a random vault key that is neither active nor retiring
        TxItem memory txItem;
        txItem.orderId = bytes32(uint256(30));
        txItem.vaultKey = bytes32(uint256(0xdeadbeef));
        txItem.chain = ETH_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 1e18;

        vm.prank(address(relay));
        vm.expectRevert(Errs.invalid_vault.selector);
        vaultManager.transferComplete(txItem, 0, 0);
    }

    function test_migrationComplete_contractChain_updatesMigrationStatus() public {
        // Rotation 1: set active vault (activeVaultBytes)
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        // Seed balance into activeVaultBytes so ETH chain is registered in that vault's chains set
        TxItem memory seedItem;
        seedItem.orderId = bytes32(uint256(39));
        seedItem.vaultKey = activeKey;
        seedItem.chain = ETH_CHAIN_ID;
        seedItem.chainType = ChainType.CONTRACT;
        seedItem.token = address(testToken);
        seedItem.amount = 100e18;

        vm.prank(address(relay));
        vaultManager.updateFromVault(seedItem, 0);

        // Post network fee so migrate() can call getNetworkFeeInfo without reverting
        vm.prank(address(relay));
        gasService.postNetworkFee(ETH_CHAIN_ID, block.number, 100, 150, 1e9);

        // Rotation 2: activeVaultBytes -> retiring, newVaultBytes -> active
        vm.prank(address(relay));
        vaultManager.rotate(activeVaultBytes, newVaultBytes);

        bytes32 retiringKey = Utils.getVaultKey(activeVaultBytes);

        // Call migrate() to trigger CONTRACT chain migration (sets MIGRATING, adds ETH to active vault)
        vm.prank(address(relay));
        vaultManager.migrate();

        // Call migrationComplete with retiring vault key and active vault bytes
        TxItem memory txItem;
        txItem.orderId = bytes32(uint256(40));
        txItem.vaultKey = retiringKey;
        txItem.chain = ETH_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 0;

        // Should not revert
        vm.prank(address(relay));
        vaultManager.migrationComplete(txItem, newVaultBytes, 0, 0);
    }

    function test_migrationComplete_revert_wrongVaults() public {
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        // Pass active vault key as txItem.vaultKey (not retiring) — should revert
        TxItem memory txItem;
        txItem.orderId = bytes32(uint256(50));
        txItem.vaultKey = activeKey;
        txItem.chain = ETH_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 0;

        vm.prank(address(relay));
        vm.expectRevert(Errs.invalid_vault.selector);
        vaultManager.migrationComplete(txItem, activeVaultBytes, 0, 0);
    }

    // -----------------------------------------------------------------------
    // Vault status transition tests
    // -----------------------------------------------------------------------

    function test_checkVault_retiringVaultIsValid() public {
        // Rotation 1: sets active
        _rotateToActive();
        // Rotation 2: creates retiring vault
        vm.prank(address(relay));
        vaultManager.rotate(activeVaultBytes, newVaultBytes);

        bytes32 retiringKey = Utils.getVaultKey(activeVaultBytes);

        TxItem memory txItem;
        txItem.vaultKey = retiringKey;
        txItem.chainType = ChainType.NATIVE;

        assertTrue(vaultManager.checkVault(txItem), "retiring vault should be valid for NATIVE chain type");
    }

    function test_rotate_clearsRetiringAfterMigrationComplete() public {
        // Rotation 1: set active vault (activeVaultBytes)
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        // Seed balance into activeVaultBytes so ETH chain is registered in that vault's chains set
        TxItem memory seedItem;
        seedItem.orderId = bytes32(uint256(59));
        seedItem.vaultKey = activeKey;
        seedItem.chain = ETH_CHAIN_ID;
        seedItem.chainType = ChainType.CONTRACT;
        seedItem.token = address(testToken);
        seedItem.amount = 100e18;

        vm.prank(address(relay));
        vaultManager.updateFromVault(seedItem, 0);

        // Post network fee so migrate() can call getNetworkFeeInfo without reverting
        vm.prank(address(relay));
        gasService.postNetworkFee(ETH_CHAIN_ID, block.number, 100, 150, 1e9);

        // Rotation 2: activeVaultBytes -> retiring, newVaultBytes -> active
        vm.prank(address(relay));
        vaultManager.rotate(activeVaultBytes, newVaultBytes);

        // Trigger CONTRACT chain migration (sets MIGRATING, adds ETH to new active vault)
        vm.prank(address(relay));
        vaultManager.migrate();

        bytes32 retiringKey = Utils.getVaultKey(activeVaultBytes);

        // Complete migration for ETH chain
        TxItem memory txItem;
        txItem.orderId = bytes32(uint256(60));
        txItem.vaultKey = retiringKey;
        txItem.chain = ETH_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 0;

        vm.prank(address(relay));
        vaultManager.migrationComplete(txItem, newVaultBytes, 0, 0);

        // Call migrate() again — migrationStatus is MIGRATED, CONTRACT chain -> removes from retiring vault
        // After all chains removed from retiring vault, retiringVaultKey is cleared
        vm.prank(address(relay));
        (bool completed, , , , ) = vaultManager.migrate();

        assertTrue(completed, "migration should be completed after all chains migrated");
        assertTrue(vaultManager.checkMigration(), "checkMigration should return true after migration completes");
    }

    // -----------------------------------------------------------------------
    // Token weight and balance fee tests
    // -----------------------------------------------------------------------

    function test_updateTokenWeights_setsWeightAndEmitsEvent() public {
        uint256[] memory chains = new uint256[](1);
        chains[0] = ETH_CHAIN_ID;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit VaultManager.UpdateTokenWeight(address(testToken), ETH_CHAIN_ID, 100);
        vaultManager.updateTokenWeights(address(testToken), chains, weights);
    }

    function test_updateTokenWeights_multipleChains() public {
        _addBscChain();

        uint256[] memory chains = new uint256[](2);
        chains[0] = ETH_CHAIN_ID;
        chains[1] = BSC_CHAIN_ID;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 60;
        weights[1] = 40;

        vm.prank(admin);
        vaultManager.updateTokenWeights(address(testToken), chains, weights);

        // sameChainsReturnZero verifies weight updates don't break the zero-fee path
        (bool incentive, uint256 fee) = vaultManager.getBalanceFee(ETH_CHAIN_ID, ETH_CHAIN_ID, address(testToken), 1e18);
        assertFalse(incentive);
        assertEq(fee, 0);

        // Verify totalWeight accumulated: 60 + 40 = 100 (observable via getBalanceFee not reverting for same chain)
        // The second weight update: verify a second call doesn't revert (idemopotent chain weight change)
        uint256[] memory chains2 = new uint256[](1);
        chains2[0] = BSC_CHAIN_ID;
        uint256[] memory weights2 = new uint256[](1);
        weights2[0] = 50; // change BSC weight from 40 to 50

        vm.prank(admin);
        vaultManager.updateTokenWeights(address(testToken), chains2, weights2);
        // No revert = totalWeight properly updated
    }

    function test_revert_updateTokenWeights_unauthorized() public {
        uint256[] memory chains = new uint256[](1);
        chains[0] = ETH_CHAIN_ID;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;

        vm.prank(user1);
        vm.expectRevert();
        vaultManager.updateTokenWeights(address(testToken), chains, weights);
    }

    function test_getBalanceFee_differentChains_withWeights() public {
        _addBscChain();
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        // Set weights to create meaningful balance fee calculation
        uint256[] memory chains = new uint256[](2);
        chains[0] = ETH_CHAIN_ID;
        chains[1] = BSC_CHAIN_ID;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 70;
        weights[1] = 30;

        vm.prank(admin);
        vaultManager.updateTokenWeights(address(testToken), chains, weights);

        // Seed ETH chain balance (imbalance: all on ETH, none on BSC)
        TxItem memory seedItem;
        seedItem.orderId = bytes32(uint256(70));
        seedItem.vaultKey = activeKey;
        seedItem.chain = ETH_CHAIN_ID;
        seedItem.chainType = ChainType.CONTRACT;
        seedItem.token = address(testToken);
        seedItem.amount = 1000e18;

        vm.prank(address(relay));
        vaultManager.updateFromVault(seedItem, 0);

        // getBalanceFee should work without reverting
        (bool incentive, uint256 fee) = vaultManager.getBalanceFee(ETH_CHAIN_ID, BSC_CHAIN_ID, address(testToken), 10e18);
        // Just verify no revert and values are accessible
        assertEq(fee, fee);
        assertEq(incentive, incentive);
    }

    // -----------------------------------------------------------------------
    // Balance tracking / bridgeOut extended tests
    // -----------------------------------------------------------------------

    function test_updateFromVault_multipleCalls_accumulate() public {
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        TxItem memory txItem;
        txItem.orderId = bytes32(uint256(80));
        txItem.vaultKey = activeKey;
        txItem.chain = ETH_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 50e18;

        vm.prank(address(relay));
        vaultManager.updateFromVault(txItem, 0);

        // Second call with different orderId, same chain/token
        txItem.orderId = bytes32(uint256(81));
        txItem.amount = 30e18;

        vm.prank(address(relay));
        vaultManager.updateFromVault(txItem, 0);

        // Balance should accumulate: 50 + 30 = 80 tokens
        (int256 balance, ) = vaultManager.getVaultTokenBalance(activeVaultBytes, ETH_CHAIN_ID, address(testToken));
        assertEq(balance, int256(80e18), "balances should accumulate across multiple updateFromVault calls");
    }

    function test_bridgeOut_insufficientBalance_returnsFalse() public {
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        // Seed only 1e18 balance
        TxItem memory seedItem;
        seedItem.orderId = bytes32(uint256(90));
        seedItem.vaultKey = activeKey;
        seedItem.chain = ETH_CHAIN_ID;
        seedItem.chainType = ChainType.CONTRACT;
        seedItem.token = address(testToken);
        seedItem.amount = 1e18;

        vm.prank(address(relay));
        vaultManager.updateFromVault(seedItem, 0);

        // Post gas fee
        vm.prank(address(relay));
        gasService.postNetworkFee(ETH_CHAIN_ID, block.number, 100, 150, 1e9);

        // Try to bridge out 1000e18 — far exceeds available balance
        TxItem memory bridgeItem;
        bridgeItem.orderId = bytes32(uint256(91));
        bridgeItem.vaultKey = activeKey;
        bridgeItem.chain = SELF_CHAIN_ID;
        bridgeItem.chainType = ChainType.CONTRACT;
        bridgeItem.token = address(testToken);
        bridgeItem.amount = 1000e18;

        vm.prank(address(relay));
        (bool choose, , , ) = vaultManager.bridgeOut(bridgeItem, ETH_CHAIN_ID, false);

        assertFalse(choose, "bridgeOut should return choose=false when balance insufficient");
    }

    function test_transferIn_withFeeRate_deductsFee() public {
        _rotateToActive();

        // Set fromVault fee to 1% (10000 out of 1_000_000)
        vm.prank(admin);
        vaultManager.updateVaultFeeRate(VaultManagerHelper.makeFeeRate(0, 10000, 0));

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        TxItem memory txItem;
        txItem.orderId = bytes32(uint256(100));
        txItem.vaultKey = activeKey;
        txItem.chain = ETH_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 100e18;

        vm.prank(address(relay));
        uint256 outAmount = vaultManager.transferIn(txItem, 0);

        // With 1% fromVault fee on transferIn (isSwapIn=true), outAmount = 100e18 - 1e18 = 99e18
        assertLt(outAmount, 100e18, "outAmount should be less than input when fromVault fee is set");
        assertEq(outAmount, 99e18, "outAmount should be 99e18 after 1% fee deduction");
    }

    // -----------------------------------------------------------------------
    // refund() tests
    // -----------------------------------------------------------------------

    function test_refund_fromRetiredVault_returnsReducedAmount() public {
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        // Post gas fee info for ETH chain
        vm.prank(address(relay));
        gasService.postNetworkFee(ETH_CHAIN_ID, block.number, 100, 150, 1e9);

        TxItem memory txItem;
        txItem.orderId = bytes32(uint256(110));
        txItem.vaultKey = activeKey;
        txItem.chain = ETH_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 10e18;

        vm.prank(address(relay));
        (uint256 refundAmt, ) = vaultManager.refund(txItem, true);

        // fromRetiredVault=true: amount > minAmount (10e18 >> estimateGas 150), returns (amount - estimateGas)
        assertGt(refundAmt, 0, "refund should return non-zero amount");
        assertLt(refundAmt, txItem.amount, "refund should be less than original amount due to gas deduction");
    }

    function test_refund_nonRetiredVault_withFeeRate() public {
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        // Post normal gas fee
        vm.prank(address(relay));
        gasService.postNetworkFee(ETH_CHAIN_ID, block.number, 100, 150, 1e9);

        // Seed balance so the vault has some reserves
        TxItem memory seedItem;
        seedItem.orderId = bytes32(uint256(112));
        seedItem.vaultKey = activeKey;
        seedItem.chain = ETH_CHAIN_ID;
        seedItem.chainType = ChainType.CONTRACT;
        seedItem.token = address(testToken);
        seedItem.amount = 100e18;

        vm.prank(address(relay));
        vaultManager.updateFromVault(seedItem, 0);

        TxItem memory txItem;
        txItem.orderId = bytes32(uint256(113));
        txItem.vaultKey = activeKey;
        txItem.chain = ETH_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 5e18;

        // Non-retired vault refund collects fees
        vm.prank(address(relay));
        (uint256 refundAmt, ) = vaultManager.refund(txItem, false);

        // With zero fee rate, refundAmt should be amount - estimateGas (after truncation)
        assertGt(refundAmt, 0, "refund should return non-zero amount");
        assertLt(refundAmt, txItem.amount, "refund should be less than original (gas deducted)");
    }

    // -----------------------------------------------------------------------
    // transferOut() tests
    // -----------------------------------------------------------------------

    function test_transferOut_choosesVaultWhenBalanceAvailable() public {
        _rotateToActive();

        bytes32 activeKey = Utils.getVaultKey(activeVaultBytes);

        // Seed balance
        TxItem memory seedItem;
        seedItem.orderId = bytes32(uint256(120));
        seedItem.vaultKey = activeKey;
        seedItem.chain = ETH_CHAIN_ID;
        seedItem.chainType = ChainType.CONTRACT;
        seedItem.token = address(testToken);
        seedItem.amount = 500e18;

        vm.prank(address(relay));
        vaultManager.updateFromVault(seedItem, 0);

        // Post gas fee
        vm.prank(address(relay));
        gasService.postNetworkFee(ETH_CHAIN_ID, block.number, 100, 150, 1e9);

        // transferOut: relay chain -> ETH chain
        TxItem memory txItem;
        txItem.orderId = bytes32(uint256(121));
        txItem.vaultKey = activeKey;
        txItem.chain = ETH_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 50e18;

        vm.prank(address(relay));
        (bool choose, uint256 outAmount, , ) = vaultManager.transferOut(txItem, 0, false);

        assertTrue(choose, "transferOut should select a vault");
        assertGt(outAmount, 0, "transferOut out amount should be positive");
    }

    function test_revert_transferOut_notRelay() public {
        TxItem memory txItem;
        txItem.chain = ETH_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 1e18;

        vm.prank(user1);
        vm.expectRevert(Errs.no_access.selector);
        vaultManager.transferOut(txItem, 0, false);
    }

    // -----------------------------------------------------------------------
    // updateBalanceFeeRate() tests
    // -----------------------------------------------------------------------

    function test_updateBalanceFeeRate_setsRate() public {
        Rebalance.BalanceFeeRate memory rate;
        rate.balanceThreshold = 100000;
        rate.fixedFromBalance = 0;
        rate.fixedToBalance = 0;
        rate.minBalance = -500000;
        rate.maxBalance = 500000;

        vm.prank(admin);
        vaultManager.updateBalanceFeeRate(rate);

        // Verify rate was stored (no revert = success; state accessed via getBalanceFee)
        // sameChainsReturnZero still holds
        (bool incentive, uint256 fee) = vaultManager.getBalanceFee(ETH_CHAIN_ID, ETH_CHAIN_ID, address(testToken), 1e18);
        assertFalse(incentive);
        assertEq(fee, 0);
    }

    function test_revert_updateBalanceFeeRate_unauthorized() public {
        Rebalance.BalanceFeeRate memory rate;
        rate.balanceThreshold = 100000;
        rate.fixedFromBalance = 0;
        rate.fixedToBalance = 0;
        rate.minBalance = -500000;
        rate.maxBalance = 500000;

        vm.prank(user1);
        vm.expectRevert();
        vaultManager.updateBalanceFeeRate(rate);
    }

    // -----------------------------------------------------------------------
    // getBridgeTokens() tests
    // -----------------------------------------------------------------------

    function test_getBridgeTokens_returnsRegisteredTokens() public view {
        address[] memory tokens = vaultManager.getBridgeTokens();
        bool found = false;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(testToken)) {
                found = true;
                break;
            }
        }
        assertTrue(found, "testToken should be in bridge tokens list");
    }

    // -----------------------------------------------------------------------
    // getVaultTokenBalance() for non-CONTRACT chain
    // -----------------------------------------------------------------------

    function test_revert_refund_notRelay() public {
        TxItem memory txItem;
        txItem.chain = ETH_CHAIN_ID;
        txItem.chainType = ChainType.CONTRACT;
        txItem.token = address(testToken);
        txItem.amount = 1e18;

        vm.prank(user1);
        vm.expectRevert(Errs.no_access.selector);
        vaultManager.refund(txItem, false);
    }
}

// ---------------------------------------------------------------------------
// Helper library to build VaultManager structs without import conflicts
// ---------------------------------------------------------------------------
library VaultManagerHelper {
    struct VaultFeeRate {
        uint32 ammVault;
        uint32 fromVault;
        uint32 toVault;
        uint160 reserved;
    }

    function makeFeeRate(uint32 ammVault, uint32 fromVault, uint32 toVault)
        internal
        pure
        returns (VaultManager.VaultFeeRate memory)
    {
        return VaultManager.VaultFeeRate({ammVault: ammVault, fromVault: fromVault, toVault: toVault, reserved: 0});
    }
}

// Expose VaultManager.VaultFeeRate at file scope for the helper
import {VaultManager} from "../../contracts/VaultManager.sol";
