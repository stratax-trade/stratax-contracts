// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {StrataxPositionNft} from "./StrataxPositionNft.sol";
import {StrataxCalculations} from "./libraries/StrataxCalculations.sol";

/**
 * @title FeeCollector
 * @notice Contract for collecting and withdrawing ERC20 token fees
 * @dev Uses OpenZeppelin's upgradeable contracts pattern
 */
contract FeeCollector is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @notice Stratax fee in basis points e.g., 5 for 0.05%
    uint256 public strataxFee;

    address public strataxPositionNft;

    uint256 public totalTradeVolume;

    /// @notice Set of all assets that have recorded trade volume
    EnumerableSet.AddressSet private _trackedAssets;

    /// @notice Mapping of asset address to cumulative trade volume
    mapping(address => uint256) public assetTradeVolume;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when fees are collected
    /// @param token Address of the token collected
    /// @param from Address that sent the fees
    /// @param amount Amount of fees collected
    event FeesCollected(address indexed token, address indexed from, uint256 indexed amount);

    /// @notice Emitted when fees are withdrawn
    /// @param token Address of the token withdrawn
    /// @param to Address that received the fees
    /// @param amount Amount of fees withdrawn
    event FeesWithdrawn(address indexed token, address indexed to, uint256 indexed amount);

    /// @notice Emitted when the fee is updated
    /// @param newFee The new fee value
    /// @param oldFee The old fee value
    event FeeUpdated(uint256 indexed newFee, uint256 indexed oldFee);

    /// @notice Emitted when trade volume is recorded
    /// @param asset Address of the asset traded
    /// @param tradeSize Size of the trade
    /// @param totalVolume Total cumulative volume for the asset
    event TradeVolumeRecorded(address indexed asset, uint256 tradeSize, uint256 totalVolume);

    /**
     * @notice Modifier to restrict function access to valid positions only
     * @dev Checks if tge msg.sender is valid stratax position
     */
    modifier onlyValidPosition() {
        require(StrataxPositionNft(strataxPositionNft).strataxAddressToTokenId(msg.sender) != 0, "Invalid position");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the FeeCollector contract
    /// @dev Can only be called once due to initializer modifier. The fee must be less than FEE_PRECISION
    /// @param _owner The address that will own the contract
    /// @param _strataxFee The initial Stratax fee in basis points
    function initialize(address _strataxPositionNft, address _owner, uint256 _strataxFee) external initializer {
        __Ownable_init(_owner);
        require(_strataxFee < StrataxCalculations.FLASHLOAN_FEE_PREC, "Fee <= 10,000");
        strataxFee = _strataxFee;
        strataxPositionNft = _strataxPositionNft;
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Collects fees by transferring tokens from sender to this contract
     * @dev Requires prior token approval. Reverts if amount is zero or token address is invalid
     * @param _feeToken The ERC20 token address
     * @param _feeAmount The amount of fees to collect
     * @param _asset The asset involved in the trade
     * @param _tradeSize The size of trade in USD for volume tracking
     */
    function collectFeesAndRecordVolume(address _feeToken, uint256 _feeAmount, address _asset, uint256 _tradeSize)
        external
        onlyValidPosition
    {
        // @dev for small trades fee can be zero, but we still want to record the trade volume
        require(_feeToken != address(0), "Invalid token address");
        require(_asset != address(0), "Invalid asset address");
        require(_tradeSize > 0, "Trade size must be greater than zero");

        if (_feeAmount > 0) {
            /// forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(_feeToken).transferFrom(msg.sender, address(this), _feeAmount);
        }

        // Track the asset if not already tracked
        if (!_trackedAssets.contains(_asset)) {
            _trackedAssets.add(_asset);
        }

        // Record trade volume
        assetTradeVolume[_asset] += _tradeSize;

        totalTradeVolume += _tradeSize;

        emit FeesCollected(_feeToken, msg.sender, _feeAmount);
        emit TradeVolumeRecorded(_asset, _tradeSize, assetTradeVolume[_asset]);
    }

    /**
     * @notice Withdraws all accumulated fees for a specific token
     * @dev Only callable by owner. Transfers entire balance to the owner
     * @param _token The ERC20 token address to withdraw
     */
    function withdrawFees(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token address");

        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(balance > 0, "No fees to withdraw");
        /// forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(_token).transfer(msg.sender, balance);

        emit FeesWithdrawn(_token, msg.sender, balance);
    }

    /**
     * @notice Sets a new Stratax fee
     * @dev Only callable by owner. New fee must be less than FEE_PRECISION
     * @param _newFee The new fee value in basis points
     */
    function setFee(uint256 _newFee) external onlyOwner {
        uint256 oldFee = strataxFee;
        require(_newFee < StrataxCalculations.FLASHLOAN_FEE_PREC, "Fee too large");
        strataxFee = _newFee;
        emit FeeUpdated(_newFee, oldFee);
    }

    /**
     * @notice Sets the StrataxPositionNft contract address
     * @dev Only callable by owner. Required for position validation
     * @param _strataxPositionNft The StrataxPositionNft contract address
     */
    function setStrataxPositionNft(address _strataxPositionNft) external onlyOwner {
        require(_strataxPositionNft != address(0), "Invalid address");
        strataxPositionNft = _strataxPositionNft;
    }

    /**
     * @notice Withdraws a specific amount of fees for a token
     * @dev Only callable by owner. Allows partial withdrawal of accumulated fees
     * @param _token The ERC20 token address to withdraw
     * @param _amount The amount to withdraw
     */
    function withdrawFees(address _token, uint256 _amount) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        require(_amount > 0, "Amount must be greater than zero");

        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(balance >= _amount, "Insufficient balance");

        bool success = IERC20(_token).transfer(msg.sender, _amount);
        require(success, "Transfer failed");

        emit FeesWithdrawn(_token, msg.sender, _amount);
    }

    /**
     * @notice Gets the total number of tracked assets
     * @return The count of assets with recorded trade volume
     */
    function getTrackedAssetsCount() external view returns (uint256) {
        return _trackedAssets.length();
    }

    /**
     * @notice Gets a tracked asset address by index
     * @param index The index in the tracked assets set
     * @return The asset address at the given index
     */
    function getTrackedAssetAt(uint256 index) external view returns (address) {
        require(index < _trackedAssets.length(), "Index out of bounds");
        return _trackedAssets.at(index);
    }

    /**
     * @notice Gets all tracked assets
     * @return An array of all tracked asset addresses
     */
    function getAllTrackedAssets() external view returns (address[] memory) {
        uint256 length = _trackedAssets.length();
        address[] memory assets = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            assets[i] = _trackedAssets.at(i);
        }
        return assets;
    }

    /**
     * @notice Gets the trade volume for a specific asset
     * @param asset The asset address to query
     * @return The cumulative trade volume for the asset
     */
    function getAssetTradeVolume(address asset) external view returns (uint256) {
        return assetTradeVolume[asset];
    }

    /**
     * @notice Gets trade volume for all tracked assets
     * @return assets Array of asset addresses
     * @return volumes Array of corresponding trade volumes
     */
    function getAllAssetVolumes() external view returns (address[] memory assets, uint256[] memory volumes) {
        uint256 length = _trackedAssets.length();
        assets = new address[](length);
        volumes = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            assets[i] = _trackedAssets.at(i);
            volumes[i] = assetTradeVolume[assets[i]];
        }

        return (assets, volumes);
    }

    /**
     * @notice Authorizes contract upgrades
     * @dev Required by UUPSUpgradeable - only allows owner to upgrade
     * @param newImplementation The address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Storage gap for future upgrades
    /// @dev Reserves 50 storage slots for adding new state variables in future upgrades without affecting storage layout
    uint256[50] private __gap;
}
