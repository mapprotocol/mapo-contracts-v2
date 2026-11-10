// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "./BaseTest.sol";
import {IMaintainers} from "../../contracts/interfaces/IMaintainers.sol";
import {ITSSManager} from "../../contracts/interfaces/ITSSManager.sol";

/// @dev distributeReward over the epoch lifecycle. TSSManager state transitions are
///      mocked so the Maintainers bookkeeping (startBlock/endBlock/migratedBlock) is driven directly.
contract MaintainersRewardTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _setMaintainerLimit(10);
        _registerAndActivateMaintainer(validator1, secp256Pubkey1, ed25519Pubkey1, maintainer1);
        _registerAndActivateMaintainer(validator2, secp256Pubkey2, ed25519Pubkey2, maintainer2);
        _registerAndActivateMaintainer(validator3, secp256Pubkey3, ed25519Pubkey3, maintainer3);
        vm.deal(address(maintainers), 10_000 ether);

        // TSSManager side effects are not under test
        vm.mockCall(address(tssManager), abi.encodeWithSelector(ITSSManager.rotate.selector), "");
        vm.mockCall(address(tssManager), abi.encodeWithSelector(ITSSManager.retire.selector), "");
        vm.mockCall(address(tssManager), abi.encodeWithSelector(ITSSManager.migrate.selector), "");
    }

    function _mockStatus(uint256 epoch, ITSSManager.TSSStatus status) internal {
        vm.mockCall(
            address(tssManager), abi.encodeWithSelector(ITSSManager.getTSSStatus.selector, epoch), abi.encode(status)
        );
    }

    function _mockElect(bool maintainersUpdate) internal {
        vm.mockCall(address(tssManager), abi.encodeWithSelector(ITSSManager.elect.selector), abi.encode(maintainersUpdate));
    }

    // Elect -> keygen completed (rotate) -> migrated (retire); new epoch becomes current
    function _fullRotation(uint256 nextEpoch) internal {
        _mockElect(true);
        maintainers.orchestrate();
        assertEq(maintainers.electionEpoch(), nextEpoch);

        vm.roll(block.number + 10);
        _mockStatus(nextEpoch, ITSSManager.TSSStatus.KEYGEN_COMPLETED);
        maintainers.orchestrate();

        vm.roll(block.number + 10);
        _mockStatus(nextEpoch, ITSSManager.TSSStatus.MIGRATED);
        maintainers.orchestrate();
        assertEq(maintainers.currentEpoch(), nextEpoch);
        _mockStatus(nextEpoch, ITSSManager.TSSStatus.ACTIVE);
    }

    function _balances() internal view returns (uint256) {
        return maintainer1.balance + maintainer2.balance + maintainer3.balance;
    }

    function _distribute() internal {
        vm.prank(address(0));
        maintainers.distributeReward();
    }

    // Epoch still running: nothing is paid
    function test_distributeReward_noPayoutWhileEpochActive() public {
        _fullRotation(1);
        vm.roll(block.number + 150);

        _distribute();
        assertEq(maintainers.rewardEpoch(), 0);
        assertEq(_balances(), 0);
    }

    // Normal rotation: epoch 1 is paid once epoch 2 has fully taken over
    function test_distributeReward_afterRotation() public {
        _fullRotation(1);
        vm.roll(block.number + 150); // past BLOCKS_PER_EPOCH (100)
        _fullRotation(2);

        IMaintainers.EpochInfo memory e1 = maintainers.getEpochInfo(1);
        assertGt(e1.migratedBlock, 0);
        uint256 expected = uint256(e1.endBlock - e1.startBlock) * 1 ether;

        _distribute();
        assertEq(maintainers.rewardEpoch(), 1);
        assertApproxEqAbs(_balances(), expected, 1e6, "epoch 1 reward (integer division dust)");

        // Paid only once
        _distribute();
        assertEq(maintainers.rewardEpoch(), 1);
        assertApproxEqAbs(_balances(), expected, 1e6);
    }

    // Same maintainer set re-elected: no keygen/migration, TSS status never becomes MIGRATED,
    // but epoch 1 must still be rewarded (the case the PR #45 change targets)
    function test_distributeReward_sameSetReElected() public {
        _fullRotation(1);
        vm.roll(block.number + 150);

        _mockElect(false); // maintainers unchanged -> no rotation
        maintainers.orchestrate();
        assertEq(maintainers.currentEpoch(), 2);
        assertEq(maintainers.electionEpoch(), 0);

        IMaintainers.EpochInfo memory e1 = maintainers.getEpochInfo(1);
        assertGt(e1.migratedBlock, 0);
        uint256 expected = uint256(e1.endBlock - e1.startBlock) * 1 ether;
        assertGt(expected, 0);

        _distribute();
        assertEq(maintainers.rewardEpoch(), 1);
        assertApproxEqAbs(_balances(), expected, 1e6, "re-elected epoch reward (integer division dust)");
    }
}
