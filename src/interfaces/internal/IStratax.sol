// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @title IStratax
 * @notice Interface for the Stratax leveraged position management contract
 * @dev This interface defines all external and public functions for the Stratax contract
 */
interface IStratax {
    /*//////////////////////////////////////////////////////////////
                            TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Parameters for opening a leveraged position via flash loan
    struct FlashLoanParams {
        address collateralToken;
        uint256 collateralAmount;
        address borrowToken;
        uint256 borrowAmount;
        bytes oneInchSwapData;
        uint256 minReturnAmount;
    }

    /// @notice Parameters for unwinding a leveraged position via flash loan
    struct UnwindParams {
        address collateralToken;
        address debtToken;
        uint256 debtAmount;
        bytes oneInchSwapData;
        uint256 minReturnAmount;
    }

    /// @notice Parameters for calculating leveraged position details
    struct TradeDetails {
        uint256 ltv;
        uint256 desiredLeverage;
        uint256 collateralAmount;
        uint256 collateralTokenPrice;
        uint256 borrowTokenPrice;
        uint256 collateralTokenDec;
        uint256 borrowTokenDec;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new leveraged position is created
    /// @param user Address of the user who created the position
    /// @param collateralToken Address of the collateral token
    /// @param borrowedToken Address of the borrowed token
    /// @param totalCollateralSupplied Total amount of collateral supplied to Aave
    /// @param borrowedAmount Amount borrowed from Aave
    /// @param healthFactor Final health factor of the position
    event LeveragePositionCreated(
        address indexed user,
        address collateralToken,
        address borrowedToken,
        uint256 totalCollateralSupplied,
        uint256 borrowedAmount,
        uint256 healthFactor
    );

    /// @notice Emitted when a leveraged position is unwound
    /// @param user Address of the user whose position was unwound
    /// @param collateralToken Address of the collateral token
    /// @param debtToken Address of the debt token
    /// @param debtRepaid Amount of debt repaid
    /// @param collateralReturned Amount of collateral withdrawn from Aave
    event PositionUnwound(
        address indexed user, address collateralToken, address debtToken, uint256 debtRepaid, uint256 collateralReturned
    );

    /*//////////////////////////////////////////////////////////////
                        INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the Stratax contract with required protocol addresses
     * @dev Can only be called once due to initializer modifier
     * @param _aavePool Address of the Aave lending pool
     * @param _aaveDataProvider Address of the Aave protocol data provider
     * @param _oneInchRouter Address of the 1inch aggregation router
     * @param _usdc Address of the USDC token
     * @param _strataxOracle Address of the Stratax price oracle
     */
    function initialize(
        address _aavePool,
        address _aaveDataProvider,
        address _oneInchRouter,
        address _usdc,
        address _strataxOracle
    ) external;

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Callback function called by Aave after receiving flash loan
     * @param _asset The flash loaned asset
     * @param _amount The flash loan amount
     * @param _premium The flash loan fee
     * @param _initiator The initiator of the flash loan
     * @param _params Encoded parameters for the operation
     * @return bool True if the operation was successful
     */
    function executeOperation(
        address _asset,
        uint256 _amount,
        uint256 _premium,
        address _initiator,
        bytes calldata _params
    ) external returns (bool);

    /**
     * @notice Unwinds a leveraged position by taking a flash loan and repaying debt
     * @param _collateralToken The collateral token held in Aave
     * @param _debtToken The debt token borrowed from Aave
     * @param _debtAmount The amount of debt to repay
     * @param _oneInchSwapData The calldata from 1inch API to swap collateral back to debt token
     * @param _minReturnAmount Minimum amount of debt token expected from swap (slippage protection)
     */
    function unwindPosition(
        address _collateralToken,
        address _debtToken,
        uint256 _debtAmount,
        bytes calldata _oneInchSwapData,
        uint256 _minReturnAmount
    ) external;

    /**
     * @notice Sets the Stratax Oracle address
     * @param _strataxOracle The new oracle address
     */
    function setStrataxOracle(address _strataxOracle) external;

    /**
     * @notice Sets the flash loan fee in basis points
     * @param _flashLoanFeeBps The flash loan fee in basis points (e.g., 9 = 0.09%)
     */
    function setFlashLoanFee(uint256 _flashLoanFeeBps) external;

    /**
     * @notice Emergency function to recover tokens sent to contract
     * @param _token The token address to recover
     * @param _amount The amount to recover
     */
    function recoverTokens(address _token, uint256 _amount) external;

    /**
     * @notice Updates the owner address
     * @param _newOwner The new owner address
     */
    function transferOwnership(address _newOwner) external;

    /*//////////////////////////////////////////////////////////////
                        PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a leveraged position by taking a flash loan
     * @param _flashLoanToken The token to flash loan (will be used as collateral)
     * @param _flashLoanAmount The amount to flash loan
     * @param _collateralAmount Additional amount from user to supply as collateral
     * @param _borrowToken The token to borrow from Aave against collateral
     * @param _borrowAmount The amount to borrow from Aave
     * @param _oneInchSwapData The calldata from 1inch API to swap borrowed token back to flash loan token
     * @param _minReturnAmount Minimum amount expected from swap (slippage protection)
     */
    function createLeveragedPosition(
        address _flashLoanToken,
        uint256 _flashLoanAmount,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount,
        bytes calldata _oneInchSwapData,
        uint256 _minReturnAmount
    ) external;

    /**
     * @notice Calculates the maximum theoretical leverage for a given LTV
     * @param _ltv The loan-to-value ratio with 4 decimals (e.g., 8000 = 80%)
     * @return maxLeverage The maximum leverage with 4 decimals (e.g., 50000 = 5x)
     */
    function getMaxLeverage(uint256 _ltv) external pure returns (uint256 maxLeverage);

    /**
     * @notice Calculates the flash loan and borrow amounts needed to achieve desired leverage
     * @param details TradeDetails struct containing leverage parameters
     * @return flashLoanAmount The amount to flash loan (in collateral token units)
     * @return borrowAmount The amount to borrow from Aave (in borrow token units)
     */
    function calculateParams(TradeDetails memory details)
        external
        view
        returns (uint256 flashLoanAmount, uint256 borrowAmount);

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the basis points constant (10000)
    function BASIS_POINTS() external view returns (uint256);

    /// @notice Returns the price feed precision constant (1e8)
    function PRICE_FEED_PREC() external view returns (uint256);

    /// @notice Returns the LTV precision constant (1e4)
    function LTV_PRECISION() external view returns (uint256);

    /// @notice Returns the leverage precision constant (1e4)
    function LEVERAGE_PRECISION() external view returns (uint256);

    /// @notice Returns the Aave lending pool address
    function aavePool() external view returns (address);

    /// @notice Returns the 1inch aggregation router address
    function oneInchRouter() external view returns (address);

    /// @notice Returns the USDC token address
    function USDC() external view returns (address);

    /// @notice Returns the Stratax price oracle address
    function strataxOracle() external view returns (address);

    /// @notice Returns the contract owner address
    function owner() external view returns (address);

    /// @notice Returns the flash loan fee in basis points
    function flashLoanFeeBps() external view returns (uint256);
}
