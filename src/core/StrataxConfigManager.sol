// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {StrataxPositionNft} from "./StrataxPositionNft.sol";
import {StrataxCalculations} from "../libraries/StrataxCalculations.sol";
import {IStrataxPositionAdapter} from "../interfaces/internal/IStrataxPositionAdapter.sol";
import {IStrataxProtocolBeacon} from "../interfaces/internal/IStrataxProtocolBeacon.sol";

/// @title StrataxConfigManager
/// @notice Manages protocol pair configuration for the Stratax system.
/// @dev Owner-gated contract that validates and applies configuration to StrataxPositionNft.
///      Centralizes all admin configuration so the NFT contract only needs to trust this one address.
contract StrataxConfigManager is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    StrataxPositionNft public positionNft;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address positionNft_) external initializer {
        __Ownable_init(owner_);
        require(positionNft_ != address(0), "Invalid position NFT");
        positionNft = StrataxPositionNft(positionNft_);
    }

    /// @notice Registers a new protocol pair (beacon + adapter) and sets platform configs in one call.
    /// @param lendingProtocolId Lending protocol identifier
    /// @param swapProtocolId Swap protocol identifier
    /// @param beacon Beacon contract for this protocol pair
    /// @param adapter Adapter contract for this protocol pair
    /// @param lendingData Encoded lending config (e.g. StrataxAaveLib.InitParams)
    /// @param swapData Encoded swap config (e.g. StrataxUniswapLib.Config)
    function registerProtocolPair(
        bytes32 lendingProtocolId,
        bytes32 swapProtocolId,
        address beacon,
        address adapter,
        bytes calldata lendingData,
        bytes calldata swapData
    ) external onlyOwner {
        _validateProtocolPairArgs(lendingProtocolId, swapProtocolId, beacon, adapter);
        require(lendingData.length > 0, "Missing lending config");
        require(swapData.length > 0, "Missing swap config");

        positionNft.setProtocolPairConfig(lendingProtocolId, swapProtocolId, beacon, adapter);
        positionNft.setPairAdapter(lendingProtocolId, swapProtocolId, adapter);
        positionNft.setLendingProtocolConfig(lendingProtocolId, lendingData);
        positionNft.setSwapProtocolConfig(swapProtocolId, swapData);
    }

    /// @notice Registers beacon + adapter without changing platform configs.
    function setProtocolPairConfig(bytes32 lendingProtocolId, bytes32 swapProtocolId, address beacon, address adapter)
        external
        onlyOwner
    {
        _validateProtocolPairArgs(lendingProtocolId, swapProtocolId, beacon, adapter);

        positionNft.setProtocolPairConfig(lendingProtocolId, swapProtocolId, beacon, adapter);
        positionNft.setPairAdapter(lendingProtocolId, swapProtocolId, adapter);
    }

    /// @notice Updates platform configs for an already-registered protocol pair.
    function setPlatformConfig(
        bytes32 lendingProtocolId,
        bytes32 swapProtocolId,
        bytes calldata lendingData,
        bytes calldata swapData
    ) external onlyOwner {
        require(lendingProtocolId != bytes32(0), "Invalid lending protocol id");
        require(swapProtocolId != bytes32(0), "Invalid swap protocol id");
        require(lendingData.length > 0, "Missing lending config");
        require(swapData.length > 0, "Missing swap config");
        positionNft.setLendingProtocolConfig(lendingProtocolId, lendingData);
        positionNft.setSwapProtocolConfig(swapProtocolId, swapData);
    }

    /// @notice Updates an adapter for an existing protocol pair.
    function setPairAdapter(bytes32 lendingProtocolId, bytes32 swapProtocolId, address adapter) external onlyOwner {
        positionNft.setPairAdapter(lendingProtocolId, swapProtocolId, adapter);
    }

    /// @notice Updates the flash loan fee for a lending protocol.
    function updatePlatformFlashLoanFee(bytes32 lendingProtocolId, uint256 newFeeBps) external onlyOwner {
        require(newFeeBps < StrataxCalculations.FLASHLOAN_FEE_PREC, "Invalid flash loan fee");
        positionNft.updateProtocolFlashLoanFee(lendingProtocolId, newFeeBps);
    }

    function _validateProtocolPairArgs(
        bytes32 lendingProtocolId,
        bytes32 swapProtocolId,
        address beacon,
        address adapter
    ) internal view {
        require(lendingProtocolId != bytes32(0), "Invalid lending protocol id");
        require(swapProtocolId != bytes32(0), "Invalid swap protocol id");
        require(beacon != address(0), "Invalid beacon");
        require(adapter != address(0), "Invalid adapter");
        require(beacon.code.length > 0, "Beacon must be contract");
        require(adapter.code.length > 0, "Adapter must be contract");

        require(
            IStrataxPositionAdapter(adapter).supportsProtocolPair(lendingProtocolId, swapProtocolId),
            "Adapter protocol ids mismatch"
        );
        require(
            IStrataxProtocolBeacon(beacon).supportsProtocolPair(lendingProtocolId, swapProtocolId),
            "Beacon protocol ids mismatch"
        );
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
