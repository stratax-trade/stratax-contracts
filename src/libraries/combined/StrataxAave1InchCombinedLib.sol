// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Stratax_Aave_1Inch as Stratax} from "../../core/position-types/Stratax_Aave_1Inch.sol";
import {StrataxAaveLib} from "../lending/StrataxAaveLib.sol";
import {Stratax1InchLib} from "../swapping/Stratax1InchLib.sol";
import {StrataxCoreLib} from "../stratax/StrataxCoreLib.sol";

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

    struct OpenPositionParams {
        uint256 collateralAmount;
        uint256 flashLoanAmount;
        uint256 borrowAmount;
        uint256 minSwapAmountOut;
        bytes data;
    }

    struct LegacyOpenPositionParams {
        uint256 collateralAmount;
        uint256 leverage;
        uint256 minSwapAmountOut;
        bytes data;
    }

    struct CreateLeveragedPositionParams {
        uint256 flashLoanAmount;
        uint256 collateralAmount;
        uint256 borrowAmount;
        bytes oneInchSwapData;
        uint256 minReturnAmount;
    }

    function decodeLendingConfig(bytes memory lendingConfigData)
        internal
        pure
        returns (StrataxAaveLib.InitParams memory lendingConfig)
    {
        lendingConfig = StrataxAaveLib.decodeConfig(lendingConfigData);
    }

    function decodeSwapConfig(bytes memory swapConfigData)
        internal
        pure
        returns (Stratax1InchLib.Config memory swapConfig)
    {
        swapConfig = Stratax1InchLib.decodeConfig(swapConfigData);
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
        (
            params.collateralAmount, params.flashLoanAmount, params.borrowAmount, params.minSwapAmountOut, params.data
        ) = abi.decode(openPositionData, (uint256, uint256, uint256, uint256, bytes));
    }

    function decodeLegacyOpenPositionParams(bytes memory openPositionData)
        internal
        pure
        returns (LegacyOpenPositionParams memory params)
    {
        (params.collateralAmount, params.leverage, params.minSwapAmountOut, params.data) =
            abi.decode(openPositionData, (uint256, uint256, uint256, bytes));
    }

    function buildInitData(
        address positionNft,
        uint256 tokenId,
        address collateralToken,
        address borrowToken,
        address pool,
        address dataProvider,
        address router,
        address strataxOracle,
        address feeCollector,
        uint256 borrowSafetyMargin,
        uint256 maxLeverageOffset
    ) internal pure returns (bytes memory initData) {
        StrataxAaveLib.PositionInitParams memory lendingParams =
            StrataxAaveLib.PositionInitParams({
                aavePool: pool,
                aaveDataProvider: dataProvider,
                borrowSafetyMargin: borrowSafetyMargin,
                maxLeverageOffset: maxLeverageOffset
            });

        Stratax1InchLib.InitParams memory swapParams = Stratax1InchLib.InitParams({oneInchRouter: router});

        StrataxCoreLib.InitParams memory strataxParams = StrataxCoreLib.InitParams({
            strataxPositionNft: positionNft,
            tokenId: tokenId,
            collateralToken: collateralToken,
            borrowToken: borrowToken,
            strataxOracle: strataxOracle,
            feeCollector: feeCollector
        });

        initData = abi.encodeWithSelector(Stratax.initialize.selector, lendingParams, swapParams, strataxParams);
    }

    function deployAndInitialize(
        bytes memory lendingConfigData,
        bytes memory swapConfigData,
        bytes memory strataxInitConfig,
        bytes32 deploymentSalt
    ) internal returns (address strataxProxy) {
        (
            StrataxAaveLib.InitParams memory lendingConfig,
            Stratax1InchLib.Config memory ignoredSwapConfig,
            StrataxInitConfig memory initConfig,
            bytes memory initData
        ) = _buildDeploymentData(lendingConfigData, swapConfigData, strataxInitConfig);

        ignoredSwapConfig;
        validateTokens(initConfig.collateralToken, initConfig.borrowToken, lendingConfig.dataProvider);
        BeaconProxy proxy = new BeaconProxy{salt: deploymentSalt}(initConfig.beacon, initData);
        strataxProxy = address(proxy);
    }

    function predictDeploymentAddress(
        bytes memory lendingConfigData,
        bytes memory swapConfigData,
        bytes memory strataxInitConfig,
        bytes32 deploymentSalt
    ) internal view returns (address predictedStrataxProxy) {
        (StrataxAaveLib.InitParams memory lendingConfig,, StrataxInitConfig memory initConfig, bytes memory initData) =
            _buildDeploymentData(lendingConfigData, swapConfigData, strataxInitConfig);

        validateTokens(initConfig.collateralToken, initConfig.borrowToken, lendingConfig.dataProvider);

        bytes memory creationCode =
            abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(initConfig.beacon, initData));
        predictedStrataxProxy = Create2.computeAddress(deploymentSalt, keccak256(creationCode), address(this));
    }

    function _buildDeploymentData(
        bytes memory lendingConfigData,
        bytes memory swapConfigData,
        bytes memory strataxInitConfig
    )
        private
        pure
        returns (
            StrataxAaveLib.InitParams memory lendingConfig,
            Stratax1InchLib.Config memory swapConfig,
            StrataxInitConfig memory initConfig,
            bytes memory initData
        )
    {
        lendingConfig = decodeLendingConfig(lendingConfigData);
        swapConfig = decodeSwapConfig(swapConfigData);
        initConfig = decodeStrataxInitConfig(strataxInitConfig);

        initData = buildInitData(
            initConfig.positionNft,
            initConfig.tokenId,
            initConfig.collateralToken,
            initConfig.borrowToken,
            lendingConfig.pool,
            lendingConfig.dataProvider,
            swapConfig.router,
            initConfig.strataxOracle,
            initConfig.feeCollector,
            lendingConfig.defaultBorrowSafetyMargin,
            lendingConfig.defaultMaxLeverageOffset
        );
    }

    function openPosition(
        address strataxProxy,
        uint256 collateralAmount,
        uint256 flashLoanAmount,
        uint256 borrowAmount,
        uint256 minSwapAmountOut,
        bytes memory data
    ) internal {
        Stratax(strataxProxy)
            .createLeveragedPosition(flashLoanAmount, collateralAmount, borrowAmount, data, minSwapAmountOut);
    }

    function openPositionLegacy(
        address strataxProxy,
        uint256 collateralAmount,
        uint256 leverage,
        uint256 minSwapAmountOut,
        bytes memory data
    ) internal {
        (uint256 flashLoanAmount, uint256 borrowAmount) = Stratax(strataxProxy)
            .calculateOpenParams(
                Stratax.CalcOpenParams({
                desiredLeverage: leverage,
                collateralAmount: collateralAmount,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
            })
            );

        Stratax(strataxProxy)
            .createLeveragedPosition(flashLoanAmount, collateralAmount, borrowAmount, data, minSwapAmountOut);
    }

    function openPositionFromEncoded(address strataxProxy, bytes memory openPositionData) internal {
        uint256 legacyOffsetWord;
        assembly {
            legacyOffsetWord := mload(add(openPositionData, 0x80))
        }

        // Backward compatible decoding for legacy payload:
        // (collateralAmount, leverage, minSwapAmountOut, data) where 4th word is bytes offset (0x80).
        if (legacyOffsetWord == 0x80) {
            LegacyOpenPositionParams memory legacyParams = decodeLegacyOpenPositionParams(openPositionData);
            openPositionLegacy(
                strataxProxy,
                legacyParams.collateralAmount,
                legacyParams.leverage,
                legacyParams.minSwapAmountOut,
                legacyParams.data
            );
            return;
        }

        OpenPositionParams memory params = decodeOpenPositionParams(openPositionData);
        openPosition(
            strataxProxy,
            params.collateralAmount,
            params.flashLoanAmount,
            params.borrowAmount,
            params.minSwapAmountOut,
            params.data
        );
    }

    function validateTokens(address collateralToken, address borrowToken, address dataProvider) internal view {
        require(StrataxAaveLib.validateTokenPair(collateralToken, borrowToken, dataProvider), "Invalid Aave token pair");
    }
}
