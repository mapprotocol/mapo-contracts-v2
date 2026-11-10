// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ISwap} from "../interfaces/swap/ISwap.sol";
import {IFlashSwap} from "../interfaces/swap/IFlashSwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseImplementation} from "@mapprotocol/common-contracts/contracts/base/BaseImplementation.sol";


contract FlashSwapManager is ISwap, BaseImplementation {

    IFlashSwap public flashSwap;

    error approve_token_failed();
    error transfer_in_failed();
    error insufficient_output();

    event SetFlashSwap(address _flashSwap);
    event Swap(address from, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, address to);

    function initialize(address _defaultAdmin) public initializer {
        __BaseImplementation_init(_defaultAdmin);
    }

    function setFlashSwap(address _flashSwap) external restricted  {
        require(_flashSwap.code.length > 0);
        flashSwap = IFlashSwap(_flashSwap);
        emit SetFlashSwap(_flashSwap);
    }

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOutMin)
    external
    override
    returns (uint256 amountOut) {
        address from = msg.sender;
        address to = address(this);
        _transferFromToken(from, tokenIn, amountIn, to);
        _approveToken(tokenIn, amountIn, address(flashSwap));
        // Measure what actually arrived instead of trusting the swap return value
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(to);
        flashSwap.swap(tokenIn, tokenOut, amountIn, amountOutMin, to);
        amountOut = IERC20(tokenOut).balanceOf(to) - balanceBefore;
        if (amountOut < amountOutMin) revert insufficient_output();
        _approveToken(tokenOut, amountOut, from);
        emit Swap(from, tokenIn, amountIn, tokenOut, amountOut, to);
    }

    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn) external view returns(uint256 amountOut) {
        amountOut = flashSwap.getAmountOut(tokenIn, tokenOut, amountIn);
    }

    function _approveToken(address token, uint256 amount, address spender) internal {
        // bytes4(keccak256(bytes('approve(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        bool result = (success && (data.length == 0 || abi.decode(data, (bool))));
        if (!result) revert approve_token_failed();
    }

    function _transferFromToken(address from, address token, uint256 amount, address receiver) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)'))); transferFrom
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, receiver, amount));
        bool result = (success && (data.length == 0 || abi.decode(data, (bool))));
        if (!result) revert transfer_in_failed();
    }

}