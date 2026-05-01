// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Stratax_Aave_1Inch as Stratax} from "../../core/position-types/Stratax_Aave_1Inch.sol";
import {StrataxAaveLib} from "../lending/StrataxAaveLib.sol";
import {Stratax1InchLib} from "../swapping/Stratax1InchLib.sol";
import {StrataxCoreLib} from "../stratax/StrataxCoreLib.sol";
import {StrataxProxyLib} from "../StrataxProxyLib.sol";

library StrataxAave1InchCombinedLib {
    struct StrataxInitConfig {
        address beacon;
        address positionNft;
        uint256 tokenId;
        address strataxOracle;
        address feeCollector;
        address collateralToken;
        address borrowToken;
    }

    struct CreateLeveragedPositionParams {
        uint256 desiredLeverage;
        uint256 collateralAmount;
        bytes oneInchSwapData;
        uint256 minReturnAmount;
    }

    function decodeStrataxInitConfig(bytes memory strataxInitConfig)
        internal
        pure
        returns (StrataxInitConfig memory initConfig)
    {
        initConfig = abi.decode(strataxInitConfig, (StrataxInitConfig));
    }

    function decodeCreateLeveragedPositionParams(bytes memory openPositionData)
        internal
        pure
        returns (CreateLeveragedPositionParams memory params)
    {
        params = abi.decode(openPositionData, (CreateLeveragedPositionParams));
    }

    function buildInitData(
        bytes memory lendingConfigData,
        bytes memory swapConfigData,
        StrataxInitConfig memory initConfig,
        address swapExecutor
    ) internal pure returns (bytes memory initData) {
        StrataxAaveLib.PositionInitParams memory lendingParams =
            StrataxAaveLib.buildPositionInitParams(lendingConfigData);
        Stratax1InchLib.InitParams memory swapParams = Stratax1InchLib.buildSwapInitParams(swapConfigData);

        StrataxCoreLib.InitParams memory strataxParams = StrataxCoreLib.InitParams({
            strataxPositionNft: initConfig.positionNft,
            tokenId: initConfig.tokenId,
            collateralToken: initConfig.collateralToken,
            borrowToken: initConfig.borrowToken,
            strataxOracle: initConfig.strataxOracle,
            feeCollector: initConfig.feeCollector
        });

        initData =
            abi.encodeWithSelector(Stratax.initialize.selector, lendingParams, swapParams, strataxParams, swapExecutor);
    }

    function deployAndInitialize(
        bytes memory lendingConfigData,
        bytes memory swapConfigData,
        bytes memory strataxInitConfigData,
        bytes32 deploymentSalt,
        address swapExecutor
    ) internal returns (address strataxProxy) {
        StrataxInitConfig memory initConfig = decodeStrataxInitConfig(strataxInitConfigData);
        StrataxAaveLib.InitParams memory lendingConfig = StrataxAaveLib.decodeConfig(lendingConfigData);
        validateTokens(initConfig.collateralToken, initConfig.borrowToken, lendingConfig.dataProvider);

        bytes memory initData = buildInitData(lendingConfigData, swapConfigData, initConfig, swapExecutor);
        strataxProxy = StrataxProxyLib.deploy(initConfig.beacon, deploymentSalt, initData);
    }

    function predictDeploymentAddress(
        bytes memory lendingConfigData,
        bytes memory swapConfigData,
        bytes memory strataxInitConfigData,
        bytes32 deploymentSalt,
        address swapExecutor
    ) internal view returns (address predictedStrataxProxy) {
        StrataxInitConfig memory initConfig = decodeStrataxInitConfig(strataxInitConfigData);
        StrataxAaveLib.InitParams memory lendingConfig = StrataxAaveLib.decodeConfig(lendingConfigData);
        validateTokens(initConfig.collateralToken, initConfig.borrowToken, lendingConfig.dataProvider);

        bytes memory initData = buildInitData(lendingConfigData, swapConfigData, initConfig, swapExecutor);
        predictedStrataxProxy =
            StrataxProxyLib.predictAddress(initConfig.beacon, deploymentSalt, initData, address(this));
    }

    function openPosition(
        address strataxProxy,
        uint256 desiredLeverage,
        uint256 collateralAmount,
        bytes memory oneInchSwapData,
        uint256 minReturnAmount
    ) internal {
        Stratax(strataxProxy)
            .createLeveragedPosition(desiredLeverage, collateralAmount, oneInchSwapData, minReturnAmount);
    }

    function openPositionFromEncoded(address strataxProxy, bytes memory openPositionData) internal {
        CreateLeveragedPositionParams memory params = decodeCreateLeveragedPositionParams(openPositionData);
        openPosition(
            strataxProxy,
            params.desiredLeverage,
            params.collateralAmount,
            params.oneInchSwapData,
            params.minReturnAmount
        );
    }

    function validateTokens(address collateralToken, address borrowToken, address dataProvider) internal view {
        require(StrataxAaveLib.validateTokenPair(collateralToken, borrowToken, dataProvider), "Invalid Aave token pair");
    }
}
