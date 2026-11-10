// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "./BaseTest.sol";
import {MockToken} from "./MockToken.sol";
import {FlashSwapManager} from "../../contracts/len/FlashSwapManager.sol";

/// @dev Pays `actualOut` but reports `reportedOut`
contract LyingFlashSwap {
    MockToken public immutable out;
    uint256 public actualOut;
    uint256 public reportedOut;

    constructor(MockToken _out) {
        out = _out;
    }

    function setAmounts(uint256 _actual, uint256 _reported) external {
        actualOut = _actual;
        reportedOut = _reported;
    }

    function swap(address, address, uint256, uint256, address to) external returns (uint256) {
        out.mint(to, actualOut);
        return reportedOut;
    }

    function getAmountOut(address, address, uint256) external view returns (uint256) {
        return reportedOut;
    }
}

contract FlashSwapManagerTest is BaseTest {
    FlashSwapManager public manager;
    LyingFlashSwap public flash;

    function setUp() public override {
        super.setUp();
        flash = new LyingFlashSwap(testToken6);
        manager = FlashSwapManager(
            _deployProxy(address(new FlashSwapManager()), abi.encodeCall(FlashSwapManager.initialize, (address(authority))))
        );
        vm.prank(admin);
        manager.setFlashSwap(address(flash));

        testToken.mint(user1, 100e18);
        vm.prank(user1);
        testToken.approve(address(manager), type(uint256).max);
    }

    // Over-reported output must not turn into a larger allowance for the caller
    function test_swap_usesActualReceivedAmount() public {
        // Leftover tokenOut held by the manager must not be claimable
        testToken6.mint(address(manager), 1_000e6);
        flash.setAmounts(10e6, 1_010e6);

        vm.prank(user1);
        uint256 out = manager.swap(address(testToken), 1e18, address(testToken6), 1);

        assertEq(out, 10e6, "must return the measured amount");
        assertEq(testToken6.allowance(address(manager), user1), 10e6, "allowance must equal received amount");
    }

    function test_revert_swap_belowMinOut() public {
        flash.setAmounts(5e6, 100e6);
        vm.prank(user1);
        vm.expectRevert(FlashSwapManager.insufficient_output.selector);
        manager.swap(address(testToken), 1e18, address(testToken6), 6e6);
    }
}
