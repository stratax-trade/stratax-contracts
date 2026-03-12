// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @title IFeeCollector
 * @notice Interface for the FeeCollector contract
 */
interface IFeeCollector {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when fees are collected
    /// @param token Address of the token collected
    /// @param from Address that sent the fees
    /// @param amount Amount of fees collected
    event FeesCollected(address indexed token, address indexed from, uint256 amount);

    /// @notice Emitted when fees are withdrawn
    /// @param token Address of the token withdrawn
    /// @param to Address that received the fees
    /// @param amount Amount of fees withdrawn
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when the fee is updated
    /// @param newFee The new fee value
    /// @param oldFee The previous fee value
    event FeeUpdated(uint256 indexed newFee, uint256 indexed oldFee);

    /// @notice Emitted when trade volume is recorded
    /// @param asset Address of the asset traded
    /// @param tradeSize Size of the trade
    /// @param totalVolume Total cumulative volume for the asset
    event TradeVolumeRecorded(address indexed asset, uint256 tradeSize, uint256 totalVolume);

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the FeeCollector contract
     * @param _owner The address that will own the contract
     * @param _strataxFee The initial Stratax fee
     */
    function initialize(address _owner, uint256 _strataxFee) external;

    /**
     * @notice Collects fees and records trade volume
     * @param _feeToken The ERC20 token address for the fee
     * @param _amount The amount of fees to collect
     * @param _asset The asset involved in the trade
     * @param _tradeSize The size of the trade
     */
    function collectFeesAndRecordVolume(address _feeToken, uint256 _amount, address _asset, uint256 _tradeSize) external;

    /**
     * @notice Withdraws all accumulated fees for a specific token
     * @param _token The ERC20 token address to withdraw
     */
    function withdrawFees(address _token) external;

    /**
     * @notice Withdraws a specific amount of fees for a token
     * @param _token The ERC20 token address to withdraw
     * @param _amount The amount to withdraw
     */
    function withdrawFees(address _token, uint256 _amount) external;

    /**
     * @notice Sets the Stratax fee
     * @param _newFee The new fee value
     */
    function setFee(uint256 _newFee) external;

    /**
     * @notice Sets the StrataxPositionNft contract address
     * @param _strataxPositionNft The StrataxPositionNft contract address
     */
    function setStrataxPositionNft(address _strataxPositionNft) external;

    /**
     * @notice Gets the balance of a specific token in the contract
     * @param _token The ERC20 token address
     * @return balance The current balance
     */
    function getBalance(address _token) external view returns (uint256 balance);

    /**
     * @notice Gets the current Stratax fee
     * @return The fee value
     */
    function strataxFee() external view returns (uint256);

    /**
     * @notice Gets the fee precision constant
     * @return The fee precision value
     */
    function FEE_PRECISION() external view returns (uint256);

    /**
     * @notice Gets the total number of tracked assets
     * @return The count of assets with recorded trade volume
     */
    function getTrackedAssetsCount() external view returns (uint256);

    /**
     * @notice Gets a tracked asset address by index
     * @param index The index in the tracked assets set
     * @return The asset address at the given index
     */
    function getTrackedAssetAt(uint256 index) external view returns (address);

    /**
     * @notice Gets all tracked assets
     * @return An array of all tracked asset addresses
     */
    function getAllTrackedAssets() external view returns (address[] memory);

    /**
     * @notice Gets the trade volume for a specific asset
     * @param asset The asset address to query
     * @return The cumulative trade volume for the asset
     */
    function getAssetTradeVolume(address asset) external view returns (uint256);

    /**
     * @notice Gets trade volume for all tracked assets
     * @return assets Array of asset addresses
     * @return volumes Array of corresponding trade volumes
     */
    function getAllAssetVolumes() external view returns (address[] memory assets, uint256[] memory volumes);

    /**
     * @notice Gets the asset trade volume mapping value
     * @param asset The asset address
     * @return The cumulative trade volume
     */
    function assetTradeVolume(address asset) external view returns (uint256);

    /**
     * @notice Gets cumulative trade volume for a Stratax proxy address
     * @param strataxProxy The Stratax proxy address
     * @return The cumulative trade volume attributed to the position
     */
    function strataxTradeVolume(address strataxProxy) external view returns (uint256);
}
