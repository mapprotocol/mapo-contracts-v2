// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IConfiguration} from "../interfaces/IConfiguration.sol";
import {BaseImplementation} from "@mapprotocol/common-contracts/contracts/base/BaseImplementation.sol";

contract Configuration is BaseImplementation, IConfiguration {

    mapping(uint256 => uint256) private chainUpdateGasFeeGap;
    mapping(uint256 => uint256) private chainConfirmationCount;

    event SetChainUpdateGasFeeGap(uint256 chainId, uint256 gap);
    event SetChainConfirmationCount(uint256 chainId, uint256 count);

    function initialize(address _defaultAdmin) public initializer {
        __BaseImplementation_init(_defaultAdmin);
    }

    function setChainUpdateGasFeeGap(uint256 chainId, uint256 gap) external restricted {
        chainUpdateGasFeeGap[chainId] = gap;
    }

    function setChainConfirmationCount(uint256 chainId, uint256 count) external restricted {
        chainConfirmationCount[chainId] = count;
    }

    function getChainUpdateGasFeeGap(uint256 chainId) external view override returns (uint256) {
        return chainUpdateGasFeeGap[chainId];
    }

    function getChainConfirmationCount(uint256 chainId) external view override returns (uint256) {
        return chainConfirmationCount[chainId];
    }
   
}
