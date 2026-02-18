// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {AggregatorV3Interface} from "./interfaces/external/AggregatorV3Interface.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract StrataxOracle is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // Mapping from token address to Chainlink price feed address
    mapping(address => address) public priceFeeds;

    /// @notice Maximum age of price data in seconds
    uint256 public maxPriceAge;

    /// @notice Emitted when a price feed is updated for a token
    event PriceFeedUpdated(address indexed token, address indexed priceFeed);

    /// @notice Emitted when the maximum price age is updated
    event MaxPriceAgeUpdated(uint256 maxPriceAge);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract (replaces constructor)
     * @param _owner The address of the contract owner
     */
    function initialize(address _owner) public initializer {
        __Ownable_init(_owner);
        maxPriceAge = 36000; // Default to 1 hour
    }

    /**
     * @notice Sets the Chainlink price feed address for a token
     * @param _token The token address
     * @param _priceFeed The Chainlink price feed address for this token
     */
    function setPriceFeed(address _token, address _priceFeed) external onlyOwner {
        _setPriceFeed(_token, _priceFeed);
        emit PriceFeedUpdated(_token, _priceFeed);
    }

    /**
     * @notice Sets multiple price feeds at once
     * @param _tokens Array of token addresses
     * @param _priceFeeds Array of corresponding price feed addresses
     */
    function setPriceFeeds(address[] calldata _tokens, address[] calldata _priceFeeds) external onlyOwner {
        require(_tokens.length == _priceFeeds.length, "Array length mismatch");

        for (uint256 i = 0; i < _tokens.length; i++) {
            _setPriceFeed(_tokens[i], _priceFeeds[i]);
            emit PriceFeedUpdated(_tokens[i], _priceFeeds[i]);
        }
    }

    /**
     * @notice Sets the maximum age for price data
     * @param _maxPriceAge The maximum age in seconds (e.g., 3600 for 1 hour)
     */
    function setMaxPriceAge(uint256 _maxPriceAge) external onlyOwner {
        maxPriceAge = _maxPriceAge;
        emit MaxPriceAgeUpdated(_maxPriceAge);
    }

    /**
     * @notice internal function for setting the price feed address
     * @param _token token address
     * @param _priceFeed chainlink price feed address
     */
    function _setPriceFeed(address _token, address _priceFeed) internal {
        require(_token != address(0), "Invalid token address");
        require(_priceFeed != address(0), "Invalid price feed address");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(_priceFeed);
        require(priceFeed.decimals() == 8, "Price feed must have 8 decimals");

        priceFeeds[_token] = _priceFeed;
    }

    function getPrice(address _token) public returns (uint256 price) {
        address priceFeedAddress = priceFeeds[_token];
        require(priceFeedAddress != address(0), "Price feed not set for token");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);

        (uint80 roundId, int256 answer,/* startedAt */, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        require(answer > 0, "Invalid price from oracle");
        require(updatedAt > 0, "Round not complete");
        require(answeredInRound >= roundId, "Stale price");

        //require(block.timestamp - updatedAt <= maxPriceAge, "Price too old"); // e.g., 3600 seconds

        price = uint256(answer);
    }

    /**
     * @notice Gets the decimals for a token's price feed
     * @param _token The token address
     * @return decimals The number of decimals in the price feed
     */
    function getPriceDecimals(address _token) public view returns (uint8 decimals) {
        address priceFeedAddress = priceFeeds[_token];
        require(priceFeedAddress != address(0), "Price feed not set for token");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
        decimals = priceFeed.decimals();
    }

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
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        address priceFeedAddress = priceFeeds[_token];
        require(priceFeedAddress != address(0), "Price feed not set for token");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
        (roundId, answer, startedAt, updatedAt, answeredInRound) = priceFeed.latestRoundData();
    }

    /**
     * @notice Required by UUPSUpgradeable - authorizes upgrades
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
