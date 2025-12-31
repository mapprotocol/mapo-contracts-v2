// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMintAbleChecker {
    function isMintable(address _token) external view returns (bool);
}