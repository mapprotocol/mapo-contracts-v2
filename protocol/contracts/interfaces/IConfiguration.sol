// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IConfiguration {
   function getChainConfirmationCount(uint256 chainId) external view returns (uint256);
   function getChainUpdateGasFeeGap(uint256 chainId) external view returns (uint256);
}
