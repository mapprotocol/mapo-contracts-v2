// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IConfiguration {
   function getIntValue(string calldata key) external view returns (int256 value);
   function getAddressValue(string calldata key) external view returns (address value);
   function getBoolValue(string calldata key) external view returns (bool value);
   function getStringValue(string calldata key) external view returns (string memory value);
   function getBytesValue(string calldata key) external view returns (bytes memory value);
}
