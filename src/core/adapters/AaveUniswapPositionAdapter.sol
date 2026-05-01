// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BasePositionAdapter} from "./BasePositionAdapter.sol";
import {ISwapExecutor} from "../interfaces/internal/ISwapExecutor.sol";
import {StrataxAaveLib} from "../../libraries/lending/StrataxAaveLib.sol";
import {StrataxUniswapLib} from "../../libraries/swapping/StrataxUniswapLib.sol";
import {StrataxAaveUniswapCombinedLib} from "../../libraries/combined/StrataxAaveUniswapCombinedLib.sol";

contract AaveUniswapPositionAdapter is BasePositionAdapter {
    bytes32 private constant LENDING_PROTOCOL_ID = keccak256("LENDING:AAVE_V3");
    bytes32 private constant SWAP_PROTOCOL_ID = keccak256("SWAP:UNISWAP_V3");

    ISwapExecutor public immutable uniswapExecutor;

    constructor(address strataxPositionNft_, ISwapExecutor _uniswapExecutor) BasePositionAdapter(strataxPositionNft_) {
        require(address(_uniswapExecutor) != address(0), "Invalid executor");
        uniswapExecutor = _uniswapExecutor;
    }

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
        StrataxAaveLib.InitParams memory lendingConfig = StrataxAaveLib.decodeConfig(lendingConfigData);
        if (!StrataxAaveLib.hasValidCoreConfig(lendingConfig)) {
            return false;
        }

        return StrataxAaveLib.validateTokenPair(collateralToken, borrowToken, lendingConfig.dataProvider);
    }

    function _validateSwapTokens(address collateralToken, address borrowToken, bytes calldata swapConfigData)
        internal
        view
        override
        returns (bool isValid)
    {
        return uniswapExecutor.validateTokenPair(collateralToken, borrowToken, swapConfigData);
    }

    function _deployAndInitialize(
        bytes calldata lendingConfigData,
        bytes calldata swapConfigData,
        bytes calldata strataxInitConfig,
        bytes32 deploymentSalt
    ) internal override returns (address strataxProxy) {
        return StrataxAaveUniswapCombinedLib.deployAndInitialize(
            lendingConfigData, swapConfigData, strataxInitConfig, deploymentSalt, address(uniswapExecutor)
        );
    }

    function _predictDeploymentAddress(
        bytes calldata lendingConfigData,
        bytes calldata swapConfigData,
        bytes calldata strataxInitConfig,
        bytes32 deploymentSalt
    ) internal view override returns (address predictedStrataxProxy) {
        return StrataxAaveUniswapCombinedLib.predictDeploymentAddress(
            lendingConfigData, swapConfigData, strataxInitConfig, deploymentSalt, address(uniswapExecutor)
        );
    }
}
