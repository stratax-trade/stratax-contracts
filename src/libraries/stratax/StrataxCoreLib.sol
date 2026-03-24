// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

library StrataxCoreLib {
    struct InitParams {
        address strataxPositionNft;
        uint256 tokenId;
        address collateralToken;
        address borrowToken;
        address strataxOracle;
        address feeCollector;
    }
}
