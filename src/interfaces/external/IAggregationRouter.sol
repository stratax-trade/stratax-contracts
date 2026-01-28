// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IAggregationRouter {
    function swap(address caller, bytes calldata desc, bytes calldata permit, bytes calldata data)
        external
        payable
        returns (uint256 returnAmount, uint256 spentAmount);
}
