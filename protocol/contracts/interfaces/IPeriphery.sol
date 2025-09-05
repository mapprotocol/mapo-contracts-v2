// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ChainType} from "../libs/Types.sol";

interface IPeriphery {
    function getAddress(uint256 t) external view returns (address addr);
    function getChainType(uint256 chain) external view returns (ChainType);
    function isRelay(address sender) external view returns (bool);
    function isTssManager(address sender) external view returns (bool);
}
