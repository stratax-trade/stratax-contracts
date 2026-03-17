// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {StrataxManagedVault} from "./StrataxManagedVault.sol";

interface IStrataxPositionNft {
    struct InitPositionParams {
        uint256 flashLoanAmount;
        uint256 collateralAmount;
        uint256 borrowAmount;
        bytes oneInchSwapData;
        uint256 minReturnAmount;
    }

    function mintPositionNft(
        address to,
        address collateralToken,
        address borrowToken,
        bool _openInitPosition,
        InitPositionParams memory _initParams
    ) external returns (uint256 tokenId, address strataxProxy);

    function transferFrom(address from, address to, uint256 tokenId) external;
}

/**
 * @title StrataxManagedVaultDeployer
 * @notice Deploys StrataxManagedVault beacon and vault proxies.
 */
contract StrataxManagedVaultDeployer is Ownable {
    using SafeERC20 for IERC20;

    address public immutable vaultImplementation;
    UpgradeableBeacon public immutable vaultBeacon;

    event VaultDeployed(
        address indexed vault, address indexed stratax, address indexed manager, string name, string symbol
    );

    event PositionAndVaultDeployed(
        address indexed positionNft, uint256 indexed tokenId, address indexed vault, address stratax, address manager
    );

    constructor(address owner_) Ownable(owner_) {
        StrataxManagedVault implementation = new StrataxManagedVault();
        vaultImplementation = address(implementation);

        UpgradeableBeacon beacon = new UpgradeableBeacon(vaultImplementation, owner_);
        vaultBeacon = beacon;
    }

    function deployVault(
        address stratax,
        address manager,
        string calldata name,
        string calldata symbol,
        uint256 initialTargetLeverage
    ) external onlyOwner returns (address vault) {
        return _deployVault(stratax, manager, name, symbol, initialTargetLeverage);
    }

    /**
     * @notice Mints a Stratax position NFT and deploys a managed vault for the minted Stratax proxy in one call.
     * @dev The minted position NFT is transferred to the newly deployed vault so the vault can manage the position.
     */
    function mintPositionAndDeployVault(
        address positionNft,
        address collateralToken,
        address borrowToken,
        bool openInitPosition,
        IStrataxPositionNft.InitPositionParams calldata initPositionParams,
        address manager,
        string calldata name,
        string calldata symbol,
        uint256 initialTargetLeverage
    ) external onlyOwner returns (uint256 tokenId, address stratax, address vault) {
        require(positionNft != address(0), "Invalid position NFT");

        IStrataxPositionNft positionNftContract = IStrataxPositionNft(positionNft);

        if (openInitPosition && initPositionParams.collateralAmount > 0) {
            IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), initPositionParams.collateralAmount);
            IERC20(collateralToken).forceApprove(positionNft, initPositionParams.collateralAmount);
        }

        (tokenId, stratax) = positionNftContract.mintPositionNft(
            address(this), collateralToken, borrowToken, openInitPosition, initPositionParams
        );

        vault = _deployVault(stratax, manager, name, symbol, initialTargetLeverage);
        positionNftContract.transferFrom(address(this), vault, tokenId);

        emit PositionAndVaultDeployed(positionNft, tokenId, vault, stratax, manager);
    }

    function _deployVault(
        address stratax,
        address manager,
        string calldata name,
        string calldata symbol,
        uint256 initialTargetLeverage
    ) internal returns (address vault) {
        bytes memory initData = abi.encodeWithSelector(
            StrataxManagedVault.initialize.selector, stratax, manager, name, symbol, initialTargetLeverage
        );

        BeaconProxy proxy = new BeaconProxy(address(vaultBeacon), initData);
        vault = address(proxy);

        emit VaultDeployed(vault, stratax, manager, name, symbol);
    }
}
