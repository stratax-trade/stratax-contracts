// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BasePositionAdapter} from "./BasePositionAdapter.sol";
import {StrataxAaveLib} from "../../libraries/lending/StrataxAaveLib.sol";
import {StrataxUniswapLib} from "../../libraries/swapping/StrataxUniswapLib.sol";
import {StrataxAaveUniswapCombinedLib} from "../../libraries/combined/StrataxAaveUniswapCombinedLib.sol";

contract AaveUniswapPositionAdapter is BasePositionAdapter {
    bytes32 private constant LENDING_PROTOCOL_ID = keccak256("LENDING:AAVE_V3");
    bytes32 private constant SWAP_PROTOCOL_ID = keccak256("SWAP:UNISWAP_V3");
    bytes32 private constant OPEN_POSITION_SCHEMA_ID = keccak256("STRATAX:OPEN_POSITION:AAVE_UNISWAP");
    uint16 private constant OPEN_POSITION_SCHEMA_VERSION = 1;

    constructor(address strataxPositionNft_) BasePositionAdapter(strataxPositionNft_) {}

    function _openPositionSchemaId() internal pure override returns (bytes32 schemaId) {
        return OPEN_POSITION_SCHEMA_ID;
    }

    function _supportedLendingProtocolId() internal pure override returns (bytes32 lendingProtocolId) {
        return LENDING_PROTOCOL_ID;
    }

    function _supportedSwapProtocolId() internal pure override returns (bytes32 swapProtocolId) {
        return SWAP_PROTOCOL_ID;
    }

    function _openPositionSchemaVersion() internal pure override returns (uint16 schemaVersion) {
        return OPEN_POSITION_SCHEMA_VERSION;
    }

    /// @notice Builds calldata for StrataxPositionNft.mintPositionByProtocolIds with Aave+Uniswap open-position params.
    /// @dev Intended for off-chain callers to prepare the full mint call payload.
    function buildCreateLeveragedPositionCallData(
        address to,
        address collateralToken,
        address borrowToken,
        bytes32 lendingProtocolId,
        bytes32 swapProtocolId,
        uint256 collateralAmount,
        uint256 leverage,
        uint24 poolFee,
        uint256 minAmountOut
    ) external pure returns (bytes memory mintCallData, bytes memory initTradeParams) {
        initTradeParams = abi.encode(collateralAmount, leverage, poolFee, minAmountOut);
        mintCallData = abi.encodeWithSignature(
            "mintPositionByProtocolIds(address,address,address,bytes32,bytes32,bool,bytes)",
            to,
            collateralToken,
            borrowToken,
            lendingProtocolId,
            swapProtocolId,
            true,
            initTradeParams
        );
    }

    function _encodeOpenPositionData(
        uint256 collateralAmount,
        uint256 leverage,
        uint256 minAmountOut,
        bytes calldata adapterData
    ) internal pure override returns (bytes memory openPositionData) {
        // Aave+Uniswap shape: (collateralAmount, leverage, poolFee, minReturnAmount)
        uint24 poolFee = abi.decode(adapterData, (uint24));
        return abi.encode(collateralAmount, leverage, poolFee, minAmountOut);
    }

    function _validateLendingTokens(address collateralToken, address borrowToken, bytes calldata lendingConfigData)
        internal
        view
        override
        returns (bool isValid)
    {
        StrataxAaveLib.InitParams memory lendingConfig = StrataxAaveLib.decodeConfig(lendingConfigData);
        if (!StrataxAaveLib.hasValidCoreConfig(lendingConfig)) {
            return false;
        }

        return StrataxAaveLib.validateTokenPair(collateralToken, borrowToken, lendingConfig.dataProvider);
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
        return StrataxAaveUniswapCombinedLib.deployAndInitialize(
            lendingConfigData, swapConfigData, strataxInitConfig, deploymentSalt
        );
    }

    function _predictDeploymentAddress(
        bytes calldata lendingConfigData,
        bytes calldata swapConfigData,
        bytes calldata strataxInitConfig,
        bytes32 deploymentSalt
    ) internal view override returns (address predictedStrataxProxy) {
        return StrataxAaveUniswapCombinedLib.predictDeploymentAddress(
            lendingConfigData, swapConfigData, strataxInitConfig, deploymentSalt
        );
    }

    function _openPosition(address strataxProxy, bytes calldata openPositionData) internal override {
        StrataxAaveUniswapCombinedLib.openPositionFromEncoded(strataxProxy, openPositionData);
    }
}
