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
     * @notice Collects fees by transferring tokens from sender to this contract
     * @param _token The ERC20 token address
     * @param _amount The amount of fees to collect
     */
    function collectFees(address _token, uint256 _amount) external;

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
}
