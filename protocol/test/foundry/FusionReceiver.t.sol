// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "./BaseTest.sol";
import {FusionReceiver} from "../../contracts/len/FusionReceiver.sol";

/// @dev Records forwarded calls instead of bridging
contract MockForwarder {
    uint256 public calls;

    function swapOutTokenWithOrderId(address, address, bytes memory, uint256, uint256, bytes32, bytes calldata)
        external
        payable
        returns (bytes32)
    {
        calls++;
        return bytes32(0);
    }

    function bridgeOutWithOrderId(bytes32, address, uint256, uint256, bytes memory, address, bytes memory, uint256)
        external
        payable
        returns (bytes32)
    {
        calls++;
        return bytes32(0);
    }
}

contract FusionReceiverTest is BaseTest {
    FusionReceiver public receiver;
    MockForwarder public mos;
    MockForwarder public gateway;

    bytes32 constant ORDER_ID = keccak256("order");
    address constant attacker = address(0xBAD);

    function setUp() public override {
        super.setUp();
        mos = new MockForwarder();
        gateway = new MockForwarder();
        receiver = FusionReceiver(
            _deployProxy(address(new FusionReceiver()), abi.encodeCall(FusionReceiver.initialize, (address(authority))))
        );
        vm.prank(admin);
        receiver.set(address(mos), address(gateway));
        // Funds of a genuinely failed order sitting in the receiver
        testToken.mint(address(receiver), 100e18);
    }

    function _payload(address to) internal pure returns (bytes memory) {
        return abi.encode(abi.encodePacked(to), uint256(56));
    }

    function _hashOf(FusionReceiver.ReceiveType t, bytes memory payload) internal view returns (bytes32) {
        return keccak256(abi.encode(t, ORDER_ID, address(testToken), uint256(100e18), uint256(1), bytes("from"), payload));
    }

    // Attacker can no longer plant a failed record through the low-gas branch
    function test_revert_onReceived_lowGasFromStranger() public {
        vm.prank(attacker);
        vm.expectRevert(FusionReceiver.only_mos_or_gateway.selector);
        receiver.onReceived{gas: 60_000}(ORDER_ID, address(testToken), 100e18, 1, "from", _payload(attacker));
        assertFalse(receiver.stored(_hashOf(FusionReceiver.ReceiveType.TSS, _payload(attacker))));
    }

    function test_revert_onReceived_stranger() public {
        vm.prank(attacker);
        vm.expectRevert(FusionReceiver.only_mos_or_gateway.selector);
        receiver.onReceived(ORDER_ID, address(testToken), 100e18, 1, "from", _payload(attacker));
    }

    // When paused, trusted callers only get their message recorded, nothing is forwarded
    function test_onReceived_pausedStoresWithoutForwarding() public {
        vm.prank(admin);
        receiver.trigger();

        vm.prank(address(gateway));
        receiver.onReceived(ORDER_ID, address(testToken), 100e18, 1, "from", _payload(user1));

        assertEq(mos.calls(), 0, "must not forward while paused");
        assertTrue(receiver.stored(_hashOf(FusionReceiver.ReceiveType.TSS, _payload(user1))));
    }

    function test_revert_retry_paused() public {
        vm.prank(admin);
        receiver.trigger();
        vm.prank(admin);
        vm.expectRevert();
        receiver.retry(FusionReceiver.ReceiveType.TSS, ORDER_ID, address(testToken), 100e18, 1, "from", _payload(user1));
    }

    // Retry is bound to the stored payload: the destination cannot be swapped
    function test_revert_retry_redirectedPayload() public {
        vm.prank(admin);
        receiver.trigger();
        vm.prank(address(gateway));
        receiver.onReceived(ORDER_ID, address(testToken), 100e18, 1, "from", _payload(user1));
        vm.prank(admin);
        receiver.trigger();

        vm.prank(admin);
        vm.expectRevert(FusionReceiver.transaction_not_exist.selector);
        receiver.retry(FusionReceiver.ReceiveType.TSS, ORDER_ID, address(testToken), 100e18, 1, "from", _payload(attacker));

        // Original payload still retries fine
        vm.prank(admin);
        receiver.retry(FusionReceiver.ReceiveType.TSS, ORDER_ID, address(testToken), 100e18, 1, "from", _payload(user1));
        assertEq(mos.calls(), 1);
    }
}
