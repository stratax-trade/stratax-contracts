// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IStrataxPositionAdapter} from "../../interfaces/internal/IStrataxPositionAdapter.sol";

abstract contract BasePositionAdapter is IStrataxPositionAdapter {
    address public immutable strataxPositionNft;

    constructor(address strataxPositionNft_) {
        require(strataxPositionNft_ != address(0), "Invalid StrataxPositionNft address");
        strataxPositionNft = strataxPositionNft_;
    }

    function supportsProtocolPair(bytes32 lendingProtocolId, bytes32 swapProtocolId)
        external
        view
        virtual
        override
        returns (bool)
    {
        return lendingProtocolId == _supportedLendingProtocolId() && swapProtocolId == _supportedSwapProtocolId();
    }

    function validateLendingTokens(address collateralToken, address borrowToken, bytes calldata lendingConfigData)
        external
        view
        virtual
        override
        returns (bool isValid)
    {
        return _validateLendingTokens(collateralToken, borrowToken, lendingConfigData);
    }

    function validateSwapTokens(address collateralToken, address borrowToken, bytes calldata swapConfigData)
        external
        view
        virtual
        override
        returns (bool isValid)
    {
        return _validateSwapTokens(collateralToken, borrowToken, swapConfigData);
    }

    function deployAndInitialize(
        bytes calldata lendingConfigData,
        bytes calldata swapConfigData,
        bytes calldata strataxInitConfig,
        bytes32 deploymentSalt
    ) external virtual override returns (address strataxProxy) {
        return _deployAndInitialize(lendingConfigData, swapConfigData, strataxInitConfig, deploymentSalt);
    }

    function predictDeploymentAddress(
        bytes calldata lendingConfigData,
        bytes calldata swapConfigData,
        bytes calldata strataxInitConfig,
        bytes32 deploymentSalt
    ) external view virtual override returns (address predictedStrataxProxy) {
        return _predictDeploymentAddress(lendingConfigData, swapConfigData, strataxInitConfig, deploymentSalt);
    }

    function _supportedLendingProtocolId() internal pure virtual returns (bytes32 lendingProtocolId);

    function _supportedSwapProtocolId() internal pure virtual returns (bytes32 swapProtocolId);

    function _validateLendingTokens(address collateralToken, address borrowToken, bytes calldata lendingConfigData)
        internal
        view
        virtual
        returns (bool isValid);

    function _validateSwapTokens(address collateralToken, address borrowToken, bytes calldata swapConfigData)
        internal
        view
        virtual
        returns (bool isValid);

    function _deployAndInitialize(
        bytes calldata lendingConfigData,
        bytes calldata swapConfigData,
        bytes calldata strataxInitConfig,
        bytes32 deploymentSalt
    ) internal virtual returns (address strataxProxy);

    function _predictDeploymentAddress(
        bytes calldata lendingConfigData,
        bytes calldata swapConfigData,
        bytes calldata strataxInitConfig,
        bytes32 deploymentSalt
    ) internal view virtual returns (address predictedStrataxProxy);
}
