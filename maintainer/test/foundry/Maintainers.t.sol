// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "./BaseTest.sol";
import {Maintainers} from "../../contracts/Maintainers.sol";
import {IMaintainers} from "../../contracts/interfaces/IMaintainers.sol";
import {IValidators} from "../../contracts/interfaces/IValidators.sol";
import {IAccounts} from "../../contracts/interfaces/IAccounts.sol";

/// @dev Unit tests for Maintainers.sol — registration lifecycle, election, jail, rewards, access control.
contract MaintainersTest is BaseTest {
    string internal constant P2P_ADDR = "/ip4/127.0.0.1/tcp/30303";

    // -------------------------------------------------------------------------
    // Registration tests
    // -------------------------------------------------------------------------

    /// @dev Validator registers maintainer — status becomes REGISTERED.
    function test_register_setsMaintainerStatus() public {
        vm.prank(validator1);
        maintainers.register(maintainer1, secp256Pubkey1, ed25519Pubkey1, P2P_ADDR);

        IMaintainers.MaintainerInfo[] memory infos = _getMaintainerInfos(maintainer1);
        assertEq(uint256(infos[0].status), uint256(IMaintainers.MaintainerStatus.REGISTERED));
        assertEq(infos[0].account, maintainer1);
    }

    /// @dev Non-validator cannot register — mock returns false for isValidator.
    function test_revert_register_notValidator() public {
        address notValidator = makeAddr("notValidator");
        // Override mock: account maps to itself, but isValidator returns false
        vm.mockCall(
            ACCOUNTS_ADDRESS,
            abi.encodeWithSelector(IAccounts.validatorSignerToAccount.selector, notValidator),
            abi.encode(notValidator)
        );
        vm.mockCall(
            VALIDATORS_ADDRESS,
            abi.encodeWithSelector(IValidators.isValidator.selector, notValidator),
            abi.encode(false)
        );

        vm.prank(notValidator);
        vm.expectRevert(Maintainers.only_validator_can_register.selector);
        maintainers.register(maintainer1, secp256Pubkey1, ed25519Pubkey1, P2P_ADDR);
    }

    /// @dev Validator cannot register twice for different maintainers.
    function test_revert_register_alreadyRegistered() public {
        vm.prank(validator1);
        maintainers.register(maintainer1, secp256Pubkey1, ed25519Pubkey1, P2P_ADDR);

        // Attempt second registration with different maintainer address
        vm.prank(validator1);
        vm.expectRevert(); // require(info.status == UNKNOWN)
        maintainers.register(maintainer2, secp256Pubkey2, ed25519Pubkey2, P2P_ADDR);
    }

    /// @dev Registering a maintainer address that's already registered to another validator reverts.
    function test_revert_register_maintainerAlreadyTaken() public {
        vm.prank(validator1);
        maintainers.register(maintainer1, secp256Pubkey1, ed25519Pubkey1, P2P_ADDR);

        // validator2 tries to register the same maintainer1 address
        vm.prank(validator2);
        vm.expectRevert(); // require(maintainerToValidator[maintainerAddr] == address(0))
        maintainers.register(maintainer1, secp256Pubkey1, ed25519Pubkey1, P2P_ADDR);
    }

    // -------------------------------------------------------------------------
    // Activation tests
    // -------------------------------------------------------------------------

    /// @dev After registration, maintainer activates — status becomes STANDBY.
    function test_activate_movesToStandby() public {
        vm.prank(validator1);
        maintainers.register(maintainer1, secp256Pubkey1, ed25519Pubkey1, P2P_ADDR);

        vm.prank(maintainer1);
        maintainers.activate();

        IMaintainers.MaintainerInfo[] memory infos = _getMaintainerInfos(maintainer1);
        assertEq(uint256(infos[0].status), uint256(IMaintainers.MaintainerStatus.STANDBY));
    }

    /// @dev Unregistered maintainer cannot activate.
    function test_revert_activate_notRegistered() public {
        vm.prank(maintainer1);
        vm.expectRevert(); // require(info.status == REGISTERED)
        maintainers.activate();
    }

    // -------------------------------------------------------------------------
    // Revoke tests
    // -------------------------------------------------------------------------

    /// @dev Maintainer in STANDBY can revoke back to REGISTERED.
    function test_revoke_movesToRegistered() public {
        vm.prank(validator1);
        maintainers.register(maintainer1, secp256Pubkey1, ed25519Pubkey1, P2P_ADDR);
        vm.prank(maintainer1);
        maintainers.activate(); // STANDBY

        vm.prank(maintainer1);
        maintainers.revoke();

        IMaintainers.MaintainerInfo[] memory infos = _getMaintainerInfos(maintainer1);
        assertEq(uint256(infos[0].status), uint256(IMaintainers.MaintainerStatus.REGISTERED));
    }

    /// @dev Cannot revoke from REGISTERED status — must be STANDBY/READY/ACTIVE.
    function test_revert_revoke_wrongStatus() public {
        vm.prank(validator1);
        maintainers.register(maintainer1, secp256Pubkey1, ed25519Pubkey1, P2P_ADDR);
        // Status is REGISTERED (not activated), so revoke should revert

        vm.prank(maintainer1);
        vm.expectRevert(); // require(status == STANDBY || READY || ACTIVE)
        maintainers.revoke();
    }

    // -------------------------------------------------------------------------
    // Deregister tests
    // -------------------------------------------------------------------------

    /// @dev Validator can deregister their maintainer — info is deleted.
    function test_deregister_removesRegistration() public {
        vm.prank(validator1);
        maintainers.register(maintainer1, secp256Pubkey1, ed25519Pubkey1, P2P_ADDR);

        vm.prank(validator1);
        maintainers.deregister();

        // After deregister, maintainerToValidator should be cleared
        assertEq(maintainers.maintainerToValidator(maintainer1), address(0));

        // Info should be reset (UNKNOWN)
        IMaintainers.MaintainerInfo[] memory infos = _getMaintainerInfos(maintainer1);
        assertEq(uint256(infos[0].status), uint256(IMaintainers.MaintainerStatus.UNKNOWN));
    }

    // -------------------------------------------------------------------------
    // Update tests
    // -------------------------------------------------------------------------

    /// @dev Validator can update maintainer keys — status becomes STANDBY.
    function test_update_changesKeysAndReactivates() public {
        vm.prank(validator1);
        maintainers.register(maintainer1, secp256Pubkey1, ed25519Pubkey1, P2P_ADDR);

        // Update to a new maintainer address (new key pair)
        string memory newP2p = "/ip4/192.168.1.1/tcp/9000";
        vm.prank(validator1);
        maintainers.update(maintainer2, secp256Pubkey2, ed25519Pubkey2, newP2p);

        // Old address mapping cleared
        assertEq(maintainers.maintainerToValidator(maintainer1), address(0));
        // New address mapped to validator1
        assertEq(maintainers.maintainerToValidator(maintainer2), validator1);

        // Status is STANDBY after update
        IMaintainers.MaintainerInfo[] memory infos = _getMaintainerInfos(maintainer2);
        assertEq(uint256(infos[0].status), uint256(IMaintainers.MaintainerStatus.STANDBY));
    }

    // -------------------------------------------------------------------------
    // Heartbeat tests
    // -------------------------------------------------------------------------

    /// @dev Registered maintainer can call heartbeat, updating lastHeartbeatTime.
    function test_heartbeat_updatesTimestamp() public {
        vm.prank(validator1);
        maintainers.register(maintainer1, secp256Pubkey1, ed25519Pubkey1, P2P_ADDR);

        uint256 beforeTime = block.timestamp;
        vm.warp(beforeTime + 100);

        vm.prank(maintainer1);
        maintainers.heartbeat();

        IMaintainers.MaintainerInfo[] memory infos = _getMaintainerInfos(maintainer1);
        assertEq(infos[0].lastHeartbeatTime, beforeTime + 100);
    }

    // -------------------------------------------------------------------------
    // getMaintainerInfos / getEpochInfo
    // -------------------------------------------------------------------------

    /// @dev getMaintainerInfos returns correct info for registered maintainer.
    function test_getMaintainerInfos_returnsInfos() public {
        vm.prank(validator1);
        maintainers.register(maintainer1, secp256Pubkey1, ed25519Pubkey1, P2P_ADDR);

        IMaintainers.MaintainerInfo[] memory infos = _getMaintainerInfos(maintainer1);
        assertEq(infos.length, 1);
        assertEq(uint256(infos[0].status), uint256(IMaintainers.MaintainerStatus.REGISTERED));
        assertEq(infos[0].account, maintainer1);
        assertEq(infos[0].secp256Pubkey, secp256Pubkey1);
        assertEq(infos[0].ed25519Pubkey, ed25519Pubkey1);
        assertEq(infos[0].p2pAddress, P2P_ADDR);
    }

    /// @dev getEpochInfo with epochId=0 returns current epoch info.
    function test_getEpochInfo_returnsCurrentEpoch() public {
        IMaintainers.EpochInfo memory info = maintainers.getEpochInfo(0);
        // Initial epoch is 0, electedBlock is 0
        assertEq(info.electedBlock, 0);
    }

    // -------------------------------------------------------------------------
    // Orchestrate / Election tests
    // -------------------------------------------------------------------------

    /// @dev First orchestrate when currentEpoch==0 triggers election immediately.
    ///      Registers 3 maintainers and activates them, then calls orchestrate.
    function test_orchestrate_electsMaintainers() public {
        // Set maintainer limit
        _setMaintainerLimit(10);

        // Register and activate 3 maintainers (validators 1-3 map to maintainers 1-3)
        _registerAndActivateMaintainer(validator1, secp256Pubkey1, ed25519Pubkey1, maintainer1);
        _registerAndActivateMaintainer(validator2, secp256Pubkey2, ed25519Pubkey2, maintainer2);
        _registerAndActivateMaintainer(validator3, secp256Pubkey3, ed25519Pubkey3, maintainer3);

        // orchestrate() for epoch 0 should trigger election immediately (_needElect returns true for epochId==0)
        maintainers.orchestrate();

        // electionEpoch should now be 1 (currentEpoch+1)
        assertGt(maintainers.electionEpoch(), 0);

        // EpochInfo for electionEpoch should have maintainers
        IMaintainers.EpochInfo memory epochInfo = maintainers.getEpochInfo(maintainers.electionEpoch());
        assertGt(epochInfo.maintainers.length, 0);
    }

    // -------------------------------------------------------------------------
    // Jail tests
    // -------------------------------------------------------------------------

    /// @dev TSSManager can jail a maintainer — status becomes JAILED.
    function test_jail_movesToJailed() public {
        // Register and activate maintainer1
        _registerAndActivateMaintainer(validator1, secp256Pubkey1, ed25519Pubkey1, maintainer1);

        address[] memory toJail = new address[](1);
        toJail[0] = maintainer1;

        // jail() can only be called by tssManager
        vm.prank(address(tssManager));
        maintainers.jail(toJail);

        IMaintainers.MaintainerInfo[] memory infos = _getMaintainerInfos(maintainer1);
        assertEq(uint256(infos[0].status), uint256(IMaintainers.MaintainerStatus.JAILED));
    }

    /// @dev Only TSSManager can call jail.
    function test_revert_jail_notTssManager() public {
        address[] memory toJail = new address[](1);
        toJail[0] = maintainer1;

        vm.prank(makeAddr("user1"));
        vm.expectRevert(Maintainers.no_access.selector);
        maintainers.jail(toJail);
    }

    // -------------------------------------------------------------------------
    // Reward distribution tests
    // -------------------------------------------------------------------------

    /// @dev distributeReward is only callable via vm (msg.sender == address(0)).
    ///      Reward requires epoch status == MIGRATED, so this tests the basic guard.
    function test_distributeReward_callableFromVm() public {
        // distributeReward() returns early until the epoch is completed
        // Since no epochs are migrated yet, it should return early without reverting
        vm.prank(address(0));
        vm.deal(address(maintainers), 1 ether);
        maintainers.distributeReward{value: 0}();
        // No revert means the function is callable from address(0)
    }

    /// @dev Non-vm callers cannot call distributeReward.
    function test_revert_distributeReward_notVm() public {
        vm.prank(makeAddr("user1"));
        vm.expectRevert(Maintainers.no_access.selector);
        maintainers.distributeReward{value: 0}();
    }

    // -------------------------------------------------------------------------
    // Access control tests
    // -------------------------------------------------------------------------

    /// @dev Unauthorized address cannot call updateMaintainerLimit.
    function test_revert_updateMaintainerLimit_unauthorized() public {
        vm.prank(makeAddr("user1"));
        vm.expectRevert(); // AccessManaged: restricted
        maintainers.updateMaintainerLimit(5);
    }

    /// @dev Admin can update maintainer limit.
    function test_updateMaintainerLimit_updatesValue() public {
        vm.prank(admin);
        maintainers.updateMaintainerLimit(5);
        assertEq(maintainers.maintainerLimit(), 5);
    }

    /// @dev Unauthorized address cannot call set.
    function test_revert_set_unauthorized() public {
        vm.prank(makeAddr("user1"));
        vm.expectRevert(); // AccessManaged: restricted
        maintainers.set(address(tssManager), address(parameters));
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _getMaintainerInfos(address maintainer) internal view returns (IMaintainers.MaintainerInfo[] memory) {
        address[] memory addrs = new address[](1);
        addrs[0] = maintainer;
        return maintainers.getMaintainerInfos(addrs);
    }
}
