// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BasePositionAdapter} from "./BasePositionAdapter.sol";
import {StrataxAaveLib} from "../../libraries/lending/StrataxAaveLib.sol";
import {Stratax1InchLib} from "../../libraries/swapping/Stratax1InchLib.sol";
import {StrataxAave1InchCombinedLib} from "../../libraries/combined/StrataxAave1InchCombinedLib.sol";

contract AaveOneInchPositionAdapter is BasePositionAdapter {
    bytes32 private constant LENDING_PROTOCOL_ID = keccak256("LENDING:AAVE_V3");
    bytes32 private constant SWAP_PROTOCOL_ID = keccak256("SWAP:ONEINCH_V6");
    bytes32 private constant OPEN_POSITION_SCHEMA_ID = keccak256("STRATAX:OPEN_POSITION:AAVE_1INCH");
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

    /// @notice Builds calldata for StrataxPositionNft.mintPositionByProtocolIds with open-position params.
    /// @dev Intended for off-chain callers that first obtain 1inch swap data, then construct the NFT mint call.
    function buildCreateLeveragedPositionCallData(
        address to,
        address collateralToken,
        address borrowToken,
        bytes32 lendingProtocolId,
        bytes32 swapProtocolId,
        uint256 collateralAmount,
        uint256 flashLoanAmount,
        uint256 borrowAmount,
        uint256 minAmountOut,
        bytes calldata oneInchSwapData
    ) external pure returns (bytes memory mintCallData, bytes memory initTradeParams) {
        initTradeParams = abi.encode(collateralAmount, flashLoanAmount, borrowAmount, minAmountOut, oneInchSwapData);
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
        // Aave+1inch shape: (collateralAmount, leverage, minSwapAmountOut, oneInchSwapData)
        return abi.encode(collateralAmount, leverage, minAmountOut, adapterData);
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
        return Stratax1InchLib.validateTokenPair(collateralToken, borrowToken, swapConfigData);
    }

    function _deployAndInitialize(
        bytes calldata lendingConfigData,
        bytes calldata swapConfigData,
        bytes calldata strataxInitConfig,
        bytes32 deploymentSalt
    ) internal override returns (address strataxProxy) {
        return StrataxAave1InchCombinedLib.deployAndInitialize(
            lendingConfigData, swapConfigData, strataxInitConfig, deploymentSalt
        );
    }

    function _predictDeploymentAddress(
        bytes calldata lendingConfigData,
        bytes calldata swapConfigData,
        bytes calldata strataxInitConfig,
        bytes32 deploymentSalt
    ) internal view override returns (address predictedStrataxProxy) {
        return StrataxAave1InchCombinedLib.predictDeploymentAddress(
            lendingConfigData, swapConfigData, strataxInitConfig, deploymentSalt
        );
    }

    function _openPosition(address strataxProxy, bytes calldata openPositionData) internal override {
        StrataxAave1InchCombinedLib.openPositionFromEncoded(strataxProxy, openPositionData);
    }
}
