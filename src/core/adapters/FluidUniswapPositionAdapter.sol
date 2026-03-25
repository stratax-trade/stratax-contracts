// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BasePositionAdapter} from "./BasePositionAdapter.sol";
import {StrataxFluidLib} from "../../libraries/lending/StrataxFluidLib.sol";
import {StrataxUniswapLib} from "../../libraries/swapping/StrataxUniswapLib.sol";
import {StrataxFluidUniswapCombinedLib} from "../../libraries/combined/StrataxFluidUniswapCombinedLib.sol";

contract FluidUniswapPositionAdapter is BasePositionAdapter {
    bytes32 private constant LENDING_PROTOCOL_ID = keccak256("LENDING:FLUID_V1");
    bytes32 private constant SWAP_PROTOCOL_ID = keccak256("SWAP:UNISWAP_V3");

    constructor(address strataxPositionNft_) BasePositionAdapter(strataxPositionNft_) {}

    function _supportedLendingProtocolId() internal pure override returns (bytes32 lendingProtocolId) {
        return LENDING_PROTOCOL_ID;
    }

    function _supportedSwapProtocolId() internal pure override returns (bytes32 swapProtocolId) {
        return SWAP_PROTOCOL_ID;
    }

    function _validateLendingTokens(address collateralToken, address borrowToken, bytes calldata lendingConfigData)
        internal
        view
        override
        returns (bool isValid)
    {
        StrataxFluidLib.InitParams memory lendingConfig = StrataxFluidLib.decodeConfig(lendingConfigData);
        if (!StrataxFluidLib.hasValidCoreConfig(lendingConfig)) {
            return false;
        }

        return StrataxFluidLib.validateTokenPair(collateralToken, borrowToken, lendingConfig.vault);
    }

    function _validateSwapTokens(address collateralToken, address borrowToken, bytes calldata swapConfigData)
        internal
        pure
        override
        returns (bool isValid)
    {
        return StrataxUniswapLib.validateTokenPair(collateralToken, borrowToken, swapConfigData);
    }

    function _deployAndInitialize(
        bytes calldata lendingConfigData,
        bytes calldata swapConfigData,
        bytes calldata strataxInitConfig,
        bytes32 deploymentSalt
    ) internal override returns (address strataxProxy) {
        return StrataxFluidUniswapCombinedLib.deployAndInitialize(
            lendingConfigData, swapConfigData, strataxInitConfig, deploymentSalt
        );
    }

    function _predictDeploymentAddress(
        bytes calldata lendingConfigData,
        bytes calldata swapConfigData,
        bytes calldata strataxInitConfig,
        bytes32 deploymentSalt
    ) internal view override returns (address predictedStrataxProxy) {
        return StrataxFluidUniswapCombinedLib.predictDeploymentAddress(
            lendingConfigData, swapConfigData, strataxInitConfig, deploymentSalt
        );
    }
}
