// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;


interface ISwap {
    function swap(address TokenIn, uint256 amountIn, address TokenOut, uint256 amountOutMin) external returns(uint256 amountOut);
}