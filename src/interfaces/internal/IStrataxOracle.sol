// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @title IStrataxOracle
 * @notice Interface for the Stratax Oracle contract that interacts with Chainlink price feeds
 * @dev This interface defines all external and public functions for the StrataxOracle contract
 */
interface IStrataxOracle {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a price feed is updated for a token
    /// @param token The token address
    /// @param priceFeed The Chainlink price feed address
    event PriceFeedUpdated(address indexed token, address indexed priceFeed);

    /// @notice Emitted when contract ownership is transferred
    /// @param previousOwner The previous owner address
    /// @param newOwner The new owner address
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the Chainlink price feed address for a token
     * @param _token The token address
     * @param _priceFeed The Chainlink price feed address for this token
     */
    function setPriceFeed(address _token, address _priceFeed) external;

    /**
     * @notice Sets multiple price feeds at once
     * @param _tokens Array of token addresses
     * @param _priceFeeds Array of corresponding price feed addresses
     */
    function setPriceFeeds(address[] calldata _tokens, address[] calldata _priceFeeds) external;

    /**
     * @notice Transfers ownership of the contract
     * @param _newOwner The address of the new owner
     */
    function transferOwnership(address _newOwner) external;

    /*//////////////////////////////////////////////////////////////
                        PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the latest price for a token from Chainlink
     * @param _token The token address
     * @return price The latest price with 8 decimals (Chainlink standard)
     */
    function getPrice(address _token) external view returns (uint256 price);

    /**
     * @notice Gets the decimals for a token's price feed
     * @param _token The token address
     * @return decimals The number of decimals in the price feed
     */
    function getPriceDecimals(address _token) external view returns (uint8 decimals);

    /**
     * @notice Gets the full round data for a token's price feed
     * @param _token The token address
     * @return roundId The round ID
     * @return answer The price
     * @return startedAt Timestamp when the round started
     * @return updatedAt Timestamp when the round was updated
     * @return answeredInRound The round ID in which the answer was computed
     */
    function getRoundData(address _token)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the contract owner address
    function owner() external view returns (address);

    /**
     * @notice Returns the Chainlink price feed address for a token
     * @param _token The token address
     * @return The price feed address
     */
    function priceFeeds(address _token) external view returns (address);
}
