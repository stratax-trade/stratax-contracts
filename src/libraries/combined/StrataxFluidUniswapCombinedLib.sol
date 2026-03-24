// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Stratax_Fluid_Uniswap as Stratax} from "../../core/position-types/Stratax_Fluid_Uniswap.sol";
import {StrataxFluidLib} from "../lending/StrataxFluidLib.sol";
import {StrataxUniswapLib} from "../swapping/StrataxUniswapLib.sol";
import {StrataxCoreLib} from "../stratax/StrataxCoreLib.sol";

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

    function decodeLendingConfig(bytes memory lendingConfigData)
        internal
        pure
        returns (StrataxFluidLib.InitParams memory lendingConfig)
    {
        lendingConfig = StrataxFluidLib.decodeConfig(lendingConfigData);
    }

    function decodeSwapConfig(bytes memory swapConfigData)
        internal
        pure
        returns (StrataxUniswapLib.Config memory swapConfig)
    {
        swapConfig = StrataxUniswapLib.decodeConfig(swapConfigData);
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
        address positionNft,
        uint256 tokenId,
        address collateralToken,
        address borrowToken,
        address vault,
        address router,
        address strataxOracle,
        address feeCollector,
        uint256 borrowSafetyMargin,
        uint256 maxLeverageOffset
    ) internal pure returns (bytes memory initData) {
        StrataxFluidLib.PositionInitParams memory lendingParams =
            StrataxFluidLib.PositionInitParams({
                fluidVault: vault, borrowSafetyMargin: borrowSafetyMargin, maxLeverageOffset: maxLeverageOffset
            });

        StrataxUniswapLib.InitParams memory swapParams = StrataxUniswapLib.InitParams({uniswapRouter: router});

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
            StrataxFluidLib.InitParams memory lendingConfig,
            StrataxUniswapLib.Config memory swapConfig,
            StrataxInitConfig memory initConfig,
            bytes memory initData
        ) = _buildDeploymentData(lendingConfigData, swapConfigData, strataxInitConfig);

        validateTokens(initConfig.collateralToken, initConfig.borrowToken, lendingConfig.vault, swapConfigData);

        swapConfig;
        BeaconProxy proxy = new BeaconProxy{salt: deploymentSalt}(initConfig.beacon, initData);
        strataxProxy = address(proxy);
    }

    function predictDeploymentAddress(
        bytes memory lendingConfigData,
        bytes memory swapConfigData,
        bytes memory strataxInitConfig,
        bytes32 deploymentSalt
    ) internal view returns (address predictedStrataxProxy) {
        (
            StrataxFluidLib.InitParams memory lendingConfig,
            StrataxUniswapLib.Config memory swapConfig,
            StrataxInitConfig memory initConfig,
            bytes memory initData
        ) = _buildDeploymentData(lendingConfigData, swapConfigData, strataxInitConfig);

        validateTokens(initConfig.collateralToken, initConfig.borrowToken, lendingConfig.vault, swapConfigData);

        swapConfig;
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
            StrataxFluidLib.InitParams memory lendingConfig,
            StrataxUniswapLib.Config memory swapConfig,
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
            lendingConfig.vault,
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
