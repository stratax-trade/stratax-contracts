// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IFluidVaultT1 {
    function LIQUIDITY() external view returns (address);

    function operate(uint256 nftId_, int256 newCol_, int256 newDebt_, address to_)
        external
        payable
        returns (uint256, int256, int256);
}
