// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IFluidLiquidity {
    function operate(
        address token_,
        int256 supplyAmount_,
        int256 borrowAmount_,
        address withdrawTo_,
        address borrowTo_,
        bytes calldata callbackData_
    ) external payable returns (uint256 supplyExchangePrice_, uint256 borrowExchangePrice_);
}
