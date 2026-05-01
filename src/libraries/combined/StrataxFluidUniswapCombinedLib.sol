// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Stratax_Fluid_Uniswap as Stratax} from "../../core/position-types/Stratax_Fluid_Uniswap.sol";
import {StrataxFluidLib} from "../lending/StrataxFluidLib.sol";
import {StrataxUniswapLib} from "../swapping/StrataxUniswapLib.sol";
import {StrataxCoreLib} from "../stratax/StrataxCoreLib.sol";
import {StrataxProxyLib} from "../StrataxProxyLib.sol";

library StrataxFluidUniswapCombinedLib {
    struct StrataxInitConfig {
        address beacon;
        address positionNft;
        uint256 tokenId;
        address strataxOracle;
        address feeCollector;
        address collateralToken;
        address borrowToken;
    }

    struct OpenPositionParams {
        uint256 collateralAmount;
        uint256 leverage;
        uint24 poolFee;
        uint256 minReturnAmount;
    }

    function decodeStrataxInitConfig(bytes memory strataxInitConfig)
        internal
        pure
        returns (StrataxInitConfig memory initConfig)
    {
        initConfig = abi.decode(strataxInitConfig, (StrataxInitConfig));
    }

    function decodeOpenPositionParams(bytes memory openPositionData)
        internal
        pure
        returns (OpenPositionParams memory params)
    {
        params = abi.decode(openPositionData, (OpenPositionParams));
    }

    function buildInitData(
        bytes memory lendingConfigData,
        bytes memory swapConfigData,
        StrataxInitConfig memory initConfig
    ) internal pure returns (bytes memory initData) {
        StrataxFluidLib.PositionInitParams memory lendingParams =
            StrataxFluidLib.buildPositionInitParams(lendingConfigData);
        StrataxUniswapLib.InitParams memory swapParams = StrataxUniswapLib.buildSwapInitParams(swapConfigData);

        StrataxCoreLib.InitParams memory strataxParams = StrataxCoreLib.InitParams({
            strataxPositionNft: initConfig.positionNft,
            tokenId: initConfig.tokenId,
            collateralToken: initConfig.collateralToken,
            borrowToken: initConfig.borrowToken,
            strataxOracle: initConfig.strataxOracle,
            feeCollector: initConfig.feeCollector
        });

        initData = abi.encodeWithSelector(Stratax.initialize.selector, lendingParams, swapParams, strataxParams);
    }

    function deployAndInitialize(
        bytes memory lendingConfigData,
        bytes memory swapConfigData,
        bytes memory strataxInitConfigData,
        bytes32 deploymentSalt
    ) internal returns (address strataxProxy) {
        StrataxInitConfig memory initConfig = decodeStrataxInitConfig(strataxInitConfigData);
        StrataxFluidLib.InitParams memory lendingConfig = StrataxFluidLib.decodeConfig(lendingConfigData);
        validateTokens(initConfig.collateralToken, initConfig.borrowToken, lendingConfig.vault, swapConfigData);

        bytes memory initData = buildInitData(lendingConfigData, swapConfigData, initConfig);
        strataxProxy = StrataxProxyLib.deploy(initConfig.beacon, deploymentSalt, initData);
    }

    function predictDeploymentAddress(
        bytes memory lendingConfigData,
        bytes memory swapConfigData,
        bytes memory strataxInitConfigData,
        bytes32 deploymentSalt
    ) internal view returns (address predictedStrataxProxy) {
        StrataxInitConfig memory initConfig = decodeStrataxInitConfig(strataxInitConfigData);
        StrataxFluidLib.InitParams memory lendingConfig = StrataxFluidLib.decodeConfig(lendingConfigData);
        validateTokens(initConfig.collateralToken, initConfig.borrowToken, lendingConfig.vault, swapConfigData);

        bytes memory initData = buildInitData(lendingConfigData, swapConfigData, initConfig);
        predictedStrataxProxy =
            StrataxProxyLib.predictAddress(initConfig.beacon, deploymentSalt, initData, address(this));
    }

    function openPosition(
        address strataxProxy,
        uint256 collateralAmount,
        uint256 leverage,
        uint24 poolFee,
        uint256 minReturnAmount
    ) internal {
        Stratax(strataxProxy).createLeveragedPosition(leverage, collateralAmount, poolFee, minReturnAmount);
    }

    function openPositionFromEncoded(address strataxProxy, bytes memory openPositionData) internal {
        OpenPositionParams memory params = decodeOpenPositionParams(openPositionData);
        openPosition(strataxProxy, params.collateralAmount, params.leverage, params.poolFee, params.minReturnAmount);
    }

    function validateTokens(address collateralToken, address borrowToken, address vault, bytes memory swapConfigData)
        internal
        pure
    {
        require(StrataxFluidLib.validateTokenPair(collateralToken, borrowToken, vault), "Invalid Fluid token pair");
        require(
            StrataxUniswapLib.validateTokenPair(collateralToken, borrowToken, swapConfigData), "Invalid Uniswap pair"
        );
    }
}
