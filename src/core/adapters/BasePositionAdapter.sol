// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IStrataxPositionAdapter} from "../../interfaces/internal/IStrataxPositionAdapter.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IStrataxLike {
    function collateralToken() external view returns (address);
}

abstract contract BasePositionAdapter is IStrataxPositionAdapter, IERC721Receiver {
    using SafeERC20 for IERC20;

    address public immutable strataxPositionNft;

    constructor(address strataxPositionNft_) {
        require(strataxPositionNft_ != address(0), "Invalid StrataxPositionNft address");
        strataxPositionNft = strataxPositionNft_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
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

    function openPositionSchemaId() external pure virtual override returns (bytes32 schemaId) {
        return _openPositionSchemaId();
    }

    function openPositionSchemaVersion() external pure virtual override returns (uint16 schemaVersion) {
        return _openPositionSchemaVersion();
    }

    function encodeOpenPositionData(
        uint256 collateralAmount,
        uint256 leverage,
        uint256 minAmountOut,
        bytes calldata adapterData
    ) external pure virtual override returns (bytes memory openPositionData) {
        return _encodeOpenPositionData(collateralAmount, leverage, minAmountOut, adapterData);
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

    function openPosition(uint256 tokenId, address strataxProxy, bytes calldata openPositionData)
        external
        virtual
        override
    {
        uint256 collateralAmount = abi.decode(openPositionData, (uint256));
        if (collateralAmount > 0) {
            address collateralToken = IStrataxLike(strataxProxy).collateralToken();
            IERC20(collateralToken).forceApprove(strataxProxy, collateralAmount);
        }

        _openPosition(strataxProxy, openPositionData);

        IERC721(strataxPositionNft).approve(strataxPositionNft, tokenId);
    }

    function _openPositionSchemaId() internal pure virtual returns (bytes32 schemaId);

    function _supportedLendingProtocolId() internal pure virtual returns (bytes32 lendingProtocolId);

    function _supportedSwapProtocolId() internal pure virtual returns (bytes32 swapProtocolId);

    function _openPositionSchemaVersion() internal pure virtual returns (uint16 schemaVersion);

    function _encodeOpenPositionData(
        uint256 collateralAmount,
        uint256 leverage,
        uint256 minAmountOut,
        bytes calldata adapterData
    ) internal pure virtual returns (bytes memory openPositionData);

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

    function _openPosition(address strataxProxy, bytes calldata openPositionData) internal virtual;
}
