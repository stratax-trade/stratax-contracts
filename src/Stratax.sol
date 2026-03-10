// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {sqrt} from "@prb-math/Common.sol";
import {IPool} from "./interfaces/external/IPool.sol";
import {IAggregationRouter} from "./interfaces/external/IAggregationRouter.sol";
import {IProtocolDataProvider} from "./interfaces/external/IProtocolDataProvider.sol";
import {IStrataxOracle} from "./interfaces/internal/IStrataxOracle.sol";
import {IStrataxPositionNft} from "./interfaces/internal/IStrataxPositionNft.sol";
import {IFeeCollector} from "./interfaces/internal/IFeeCollector.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StrataxCalculations} from "./libraries/StrataxCalculations.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/*
  _________ __                 __
 /   _____//  |_____________ _/  |______  ___  ___
 \_____  \\   __\_  __ \__  \\   __\__  \ \  \/  /
 /        \|  |  |  | \// __ \|  |  / __ \_>    <
/_______  /|__|  |__|  (____  /__| (____  /__/\_ \
        \/                  \/          \/      \/
Author: Marquis Harris
*/

/**
 * @title Stratax
 * @author Marquis Harris
 * @notice Represents a leveraged position powered by Aave and 1inch
 * @dev This contract is minted by the StrataxPositionNft contract as a beacon proxy
 * which will set the collateral token and borrow token. Each contract is only meant
 * to hold one type of position i.e. long ETH if you want to short ETH you need to mint
 * another NFT with the collateral as USDC and the borrow token as ETH.
 *
 * Leveraged positions are opened in the following steps:
 * 1. Supplying collateral from the user to Aave
 * 2. Taking Aave flash loan and supplying additional collateral
 * 3. Borrowing against toal supplied collateral
 * 4. Swapping the received borrowed token through 1inch back to collateral token
 * 5. Repay the flashloan with the amount recieved from swapping
 * Result is a short or long position.
 *
 * @dev In addition to the functions opening or closing leveraged positions
 * there are functions to manage the position's health with repay, borrow
 *
 */
contract Stratax is Initializable, ReentrancyGuardTransient {
    /* @dev note are and debugging area */
    //
    //
    //
    //

    /*//////////////////////////////////////////////////////////////
                            TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;

    /// @notice Enum for flash loan operation types
    enum OperationType {
        /// @notice Opening/Increasing leveraged position
        OPEN,
        /// @notice Unwinding an existing leveraged position
        UNWIND
    }

    /// @notice Parameters for opening a leveraged position via flash loan
    struct FlashLoanParams {
        /// @notice Address of the token used as collateral
        address collateralToken;
        /// @notice Amount of additional collateral provided by user
        uint256 collateralAmount;
        /// @notice Address of the token to borrow from Aave
        address borrowToken;
        /// @notice Amount to borrow from Aave
        uint256 borrowAmount;
        /// @notice Encoded calldata for 1inch swap
        bytes oneInchSwapData;
        /// @notice Minimum acceptable amount from swap (slippage protection)
        uint256 minReturnAmount;
    }

    /// @notice Parameters for unwinding a leveraged position via flash loan
    struct UnwindParams {
        /// @notice Address of the collateral token held in Aave
        address collateralToken;
        /// @notice Amount of collateral to withdraw from Aave
        uint256 collateralToWithdraw;
        /// @notice Address of the debt token borrowed from Aave
        address debtToken;
        /// @notice Amount of debt to repay
        uint256 debtAmount;
        /// @notice Encoded calldata for 1inch swap
        bytes oneInchSwapData;
        /// @notice Minimum acceptable amount from swap (slippage protection)
        uint256 minReturnAmount;
    }

    /// @notice Parameters for calculating leveraged position _params
    struct CalcOpenParams {
        /// @notice Desired leverage multiplier with 4 decimals (e.g., 30000 = 3x)
        uint256 desiredLeverage;
        /// @notice Amount of collateral the user will provide
        uint256 collateralAmount;
        /// @notice Price of collateral token in USD with 8 decimals
        uint256 collateralTokenPrice;
        /// @notice Price of borrow token in USD with 8 decimals
        uint256 borrowTokenPrice;
    }

    /// @notice Struct for Stratax initialization parameters
    struct StrataxInitParams {
        address aavePool;
        address aaveDataProvider;
        address oneInchRouter;
        address strataxPositionNft;
        uint256 tokenId;
        address collateralToken;
        address borrowToken;
        address strataxOracle;
        address feeCollector;
        uint256 borrowSafetyMargin;
        uint256 maxLeverageOffset;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Aave variable debt interest rate mode identifier
    uint256 public constant VARIABLE_DEBT = 2;

    /// @notice Default unwind slippage buffer in basis points (50 = 0.50%)
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 50;

    /// @notice tokenId which represents this contract in the StrataxPositionNft
    uint256 public tokenId;

    /// @notice if the token has been burned
    bool public isBurned;

    /// @notice owner of the the burned token
    address public burnedTokenOwner;

    /// @notice Safety margin for borrow calculations (9900 = 99% of max LTV)
    /// @dev This ensures positions have a healthy buffer and don't immediately risk liquidation
    uint256 public borrowSafetyMargin; // 99% of max LTV for Aave collateral

    /// @notice Offset from maximum leverage with 4 decimals (e.g., 75 = 0.75%)
    /// @dev When nearing max leverage, slippage or price fluctuation can cause reverts.
    ///      This offset provides a safety buffer by reducing the effective LTV used in calculations.
    uint256 public maxLeverageOffset; // default is 75 which means 0.75% of the borrow safety margin can be used for leverage

    /// @notice StrataxPositionNft contract for tracking ownership
    IStrataxPositionNft public strataxPositionNft;

    /// @notice Aave lending pool interface for flash loans and lending operations
    IPool public aavePool;

    /// @notice Aave protocol data provider for querying reserve configurations
    IProtocolDataProvider public aaveDataProvider;

    /// @notice 1inch aggregation router interface for token swaps
    IAggregationRouter public oneInchRouter;

    /// @notice Collateral token address for this position
    address public collateralToken;

    /// @notice Borrow token address for this position
    address public borrowToken;

    /// @notice Decimals of the collateral token
    uint256 public collateralTokenDecimals;

    /// @notice Decimals of the borrow token
    uint256 public borrowTokenDecimals;

    /// @notice Address of the Stratax price oracle contract
    address public strataxOracle;

    /// @notice Address for the fee collector which takes a opening and closing fee
    address public feeCollector;

    /// @notice Flash loan fee in basis points (e.g., 9 = 0.09%)
    uint256 public flashLoanFeeBps;

    /// @notice Storage gap for future upgrades (reserve space for 50 new state variables)
    /// @dev This prevents storage collisions when adding new state variables in upgrades
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new leveraged position is created
    /// @param user Address of the user who created the position
    /// @param collateralToken Address of the collateral token
    /// @param borrowedToken Address of the borrowed token
    /// @param totalCollateralSupplied Total amount of collateral supplied to Aave
    /// @param borrowedAmount Amount borrowed from Aave
    event LeveragePositionCreated(
        address indexed user,
        address collateralToken,
        address borrowedToken,
        uint256 totalCollateralSupplied,
        uint256 borrowedAmount
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

    /// @notice Emitted when collateral is added to a position
    /// @param user Address of the user who supplied collateral
    /// @param collateralToken Address of the collateral token
    /// @param amount Amount of collateral supplied
    /// @param healthFactor Health factor after supplying collateral
    event CollateralSupplied(address indexed user, address collateralToken, uint256 amount, uint256 healthFactor);

    /// @notice Emitted when the max leverage offset is updated
    /// @param newOffset The new max leverage offset
    /// @param oldOffset The previous max leverage offset
    event MaxLeverageOffsetUpdated(uint256 newOffset, uint256 oldOffset);

    /// @notice Emitted when the 1inch router is updated
    /// @param newRouter Address of the new 1inch router
    /// @param oldRouter Address of the old 1inch router
    event OneInchRouterUpdated(address newRouter, address oldRouter);

    /// @notice Emitted when collateral is withdrawn from a position
    /// @param user Address of the user who withdrew collateral
    /// @param collateralToken Address of the collateral token
    /// @param amount Amount of collateral withdrawn
    /// @param healthFactor Health factor after withdrawing collateral
    event CollateralWithdrawn(address indexed user, address collateralToken, uint256 amount, uint256 healthFactor);

    /// @notice Emitted when the flash loan fee is updated
    /// @param newFeeBps The new flash loan fee in basis points
    /// @param oldFeeBps The previous flash loan fee in basis points
    event FlashLoanFeeUpdated(uint256 newFeeBps, uint256 oldFeeBps);

    /// @notice Emitted when the borrow safety margin is updated
    /// @param newMargin The new borrow safety margin
    /// @param oldMargin The previous borrow safety margin
    event BorrowSafetyMarginUpdated(uint256 newMargin, uint256 oldMargin);

    /// @notice Emitted when a position is partially unwound
    /// @param user Address of the user whose position was partially unwound
    /// @param collateralToken Address of the collateral token
    /// @param debtToken Address of the debt token
    /// @param debtRepaid Amount of debt repaid
    /// @param collateralReturned Amount of collateral returned
    event PositionPartiallyUnwound(
        address indexed user, address collateralToken, address debtToken, uint256 debtRepaid, uint256 collateralReturned
    );

    /// @notice Emitted when a position is partially increased
    /// @param user Address of the user whose position was increased
    /// @param collateralToken Address of the collateral token
    /// @param borrowedToken Address of the borrowed token
    /// @param additionalCollateralSupplied Additional amount of collateral supplied
    /// @param additionalBorrowedAmount Additional amount borrowed
    event PositionPartiallyIncreased(
        address indexed user,
        address collateralToken,
        address borrowedToken,
        uint256 additionalCollateralSupplied,
        uint256 additionalBorrowedAmount
    );

    /// @notice Emitted when a position's health factor is updated
    /// @param user Address of the user whose position health was updated
    /// @param healthFactor The new health factor
    event PositionHealthUpdated(address indexed user, uint256 healthFactor);

    /// @notice Emitted when tokens are emergency withdrawn from the contract
    /// @param user Address of the user who withdrew tokens
    /// @param token Address of the token withdrawn
    /// @param amount Amount of tokens withdrawn
    event EmergencyWithdrawal(address indexed user, address token, uint256 amount);

    /// @notice Emitted when a position is fully closed
    /// @param user Address of the user whose position was closed
    event PositionClosed(address indexed user);

    /// @notice Emitted when a position is burned
    /// @param user Address of the user whose position was burned
    /// @param tokenId The ID of the burned position
    event PositionBurned(address indexed user, uint256 tokenId);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts function access to contract owner only
    modifier onlyOwner() {
        if (isBurned) {
            require(msg.sender == burnedTokenOwner, "Not Owner");
        } else {
            require(msg.sender == strataxPositionNft.ownerOf(tokenId), "Not Owner");
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the Stratax contract with required protocol addresses
    /// @dev Can only be called once due to initializer modifier
    /// @param params Struct containing all initialization parameters
    function initialize(StrataxInitParams calldata params) external initializer {
        aavePool = IPool(params.aavePool);
        aaveDataProvider = IProtocolDataProvider(params.aaveDataProvider);
        oneInchRouter = IAggregationRouter(params.oneInchRouter);
        strataxPositionNft = IStrataxPositionNft(params.strataxPositionNft);
        tokenId = params.tokenId;
        collateralToken = params.collateralToken;
        borrowToken = params.borrowToken;
        strataxOracle = params.strataxOracle;
        flashLoanFeeBps = aavePool.FLASHLOAN_PREMIUM_TOTAL(); // Default 0.05% Aave flash loan fee
        feeCollector = params.feeCollector;
        maxLeverageOffset = params.maxLeverageOffset;

        // Fetch and store token decimals
        collateralTokenDecimals = IERC20Metadata(params.collateralToken).decimals();
        borrowTokenDecimals = IERC20Metadata(params.borrowToken).decimals();

        // Set borrow safety margin with default if not provided
        if (params.borrowSafetyMargin == 0) {
            borrowSafetyMargin = 9900; // Default to 99% of max LTV
        } else {
            require(params.borrowSafetyMargin < StrataxCalculations.BORROW_SAFETY_PRECISION, "Invalid safety margin");
            borrowSafetyMargin = params.borrowSafetyMargin;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates the flash loan and borrow amounts needed to achieve desired leverage
     * @param _params struct containing:
     *        - desiredLeverage: The desired leverage multiplier with 4 decimals (e.g., 30000 = 3x)
     *        - collateralAmount: The amount of collateral the user will provide (in collateral token units)
     *        - collateralTokenPrice: Price of collateral token in USD with 8 decimals
     *        - borrowTokenPrice: Price of borrow token in USD with 8 decimals
     * @return flashLoanAmount The amount to flash loan (in collateral token units)
     * @return borrowAmount The amount to borrow from Aave (in borrow token units)
     * @dev for off-chain use
     */
    function calculateOpenParams(CalcOpenParams memory _params)
        public
        view
        returns (uint256 flashLoanAmount, uint256 borrowAmount)
    {
        // Get LTV from Aave for the collateral token
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(collateralToken);
        require(ltv > 0, "Asset not usable as collateral");

        // If collateral token price is zero, fetch it from the oracle
        if (_params.collateralTokenPrice == 0) {
            require(strataxOracle != address(0), "Oracle not set");
            _params.collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        }

        // If borrow token price is zero, fetch it from the oracle
        if (_params.borrowTokenPrice == 0) {
            require(strataxOracle != address(0), "Oracle not set");
            _params.borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        }

        uint256 freeCollateral = _getFreeCollateral(_params.collateralTokenPrice, _params.borrowTokenPrice, ltv);
        _params.collateralAmount = _params.collateralAmount + freeCollateral;

        // Use the library to perform the calculation (leverage capping is done inside the library)
        StrataxCalculations.CalcParams memory calcParams = StrataxCalculations.CalcParams({
            desiredLeverage: _params.desiredLeverage,
            collateralAmount: _params.collateralAmount,
            collateralTokenPrice: _params.collateralTokenPrice,
            borrowTokenPrice: _params.borrowTokenPrice,
            collateralTokenDecimals: collateralTokenDecimals,
            borrowTokenDecimals: borrowTokenDecimals,
            ltv: ltv,
            borrowSafetyMargin: borrowSafetyMargin,
            flashLoanFeeBps: flashLoanFeeBps,
            strataxFeeBps: IFeeCollector(feeCollector).strataxFee(),
            maxLeverageOffset: maxLeverageOffset
        });

        StrataxCalculations.CalcResult memory result = StrataxCalculations.calculateOpenParams(calcParams);

        return (result.flashLoanAmount, result.borrowAmount);
    }

    /**
     * @notice Calculates the amount of collateral to withdraw and debt to repay for unwinding a position
     * @param _debtToRepay the amount of debt to repay on the position reducing the position size
     * @return collateralToWithdraw The amount of collateral to withdraw from Aave (includes default slippage buffer)
     * @return debtAmount The total debt amount to repay
     * @return strataxFee The Stratax protocol fee amount
     */
    function calculateUnwindParams(uint256 _debtToRepay)
        public
        view
        returns (uint256 collateralToWithdraw, uint256 debtAmount, uint256 strataxFee)
    {
        return calculateUnwindParams(_debtToRepay, DEFAULT_SLIPPAGE_BPS);
    }

    /**
     * @notice Calculates the amount of collateral to withdraw and debt to repay for unwinding a position
     * @param _debtToRepay the amount of debt to repay on the position reducing the position size
     * @param _slippageBufferBps Slippage buffer in basis points
     * @return collateralToWithdraw The amount of collateral to withdraw from Aave (includes slippage buffer)
     * @return debtAmount The total debt amount to repay
     * @return strataxFee The Stratax protocol fee amount
     * @dev if the _debtTeRepay is equal to or more than the actual debt, the position will be fully closed
     */
    function calculateUnwindParams(uint256 _debtToRepay, uint256 _slippageBufferBps)
        public
        view
        returns (uint256 collateralToWithdraw, uint256 debtAmount, uint256 strataxFee)
    {
        // Get the address of the debt token
        (,, address debtToken) = aaveDataProvider.getReserveTokensAddresses(borrowToken);
        debtAmount = IERC20(debtToken).balanceOf(address(this));
        if (debtAmount <= _debtToRepay) {
            _debtToRepay = debtAmount;
        }

        uint256 debtTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        strataxFee = (_debtToRepay * IFeeCollector(feeCollector).strataxFee()) / StrataxCalculations.FLASHLOAN_FEE_PREC;
        uint256 flashLoanFeeAmount = (_debtToRepay * flashLoanFeeBps) / StrataxCalculations.FLASHLOAN_FEE_PREC;
        // Include protocol fee in required unwind amount so fee collection can be funded from swap proceeds.
        collateralToWithdraw =
            (debtTokenPrice * (_debtToRepay + flashLoanFeeAmount + strataxFee) * 10 ** collateralTokenDecimals)
                / (collateralTokenPrice * 10 ** borrowTokenDecimals);

        // Account for slippage in swap, we will re-supply the excess amount to aave
        collateralToWithdraw =
            (collateralToWithdraw * (StrataxCalculations.BPS + _slippageBufferBps)) / StrataxCalculations.BPS; // There should Always be enough collateral to unwind a position

        return (collateralToWithdraw, _debtToRepay, strataxFee);
    }

    /**
     * @notice Creates a leveraged position using flash loans and Aave V3
     * @dev Process:
     *      1. User transfers collateral to contract
     *      2. Flash loan additional collateral
     *      3. Pay Stratax fee
     *      4. Supply total collateral (user + flash loan) to Aave
     *      5. Borrow debt tokens from Aave
     *      6. Swap debt tokens to collateral via 1inch
     *      7. Repay flash loan with swap proceeds
     *      8. Supply any leftover collateral to Aave
     * @param _flashLoanAmount Amount to flash loan (from calculateOpenParams)
     * @param _collateralAmount Amount of collateral user provides
     * @param _borrowAmount Amount to borrow from Aave (from calculateOpenParams)
     * @param _oneInchSwapData Encoded calldata from 1inch API for debt → collateral swap
     * @param _minReturnAmount Minimum collateral expected from swap for slippage protection
     */
    function createLeveragedPosition(
        uint256 _flashLoanAmount,
        uint256 _collateralAmount,
        uint256 _borrowAmount,
        bytes calldata _oneInchSwapData,
        uint256 _minReturnAmount
    ) public onlyOwner {
        require(!isBurned, "Position is burned, only unwinding allowed");

        uint256 currentCollateralBalance = IERC20(collateralToken).balanceOf(address(this));
        if (currentCollateralBalance > 0) {
            //supply any inactive collateral
            IERC20(collateralToken).forceApprove(address(aavePool), currentCollateralBalance);
            aavePool.supply(collateralToken, currentCollateralBalance, address(this), 0);
        }

        if (_collateralAmount > 0) {
            // Transfer the user's collateral to the contract
            IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), _collateralAmount);
        }

        FlashLoanParams memory params = FlashLoanParams({
            collateralToken: collateralToken,
            collateralAmount: _collateralAmount,
            borrowToken: borrowToken,
            borrowAmount: _borrowAmount,
            oneInchSwapData: _oneInchSwapData,
            minReturnAmount: _minReturnAmount
        });

        bytes memory encodedParams = abi.encode(OperationType.OPEN, msg.sender, params);

        // Initiate flash loan
        aavePool.flashLoanSimple(address(this), address(collateralToken), _flashLoanAmount, encodedParams, 0);
    }

    /**
     * @notice Unwinds a leveraged position by closing the Aave debt and recovering collateral
     * @dev Process:
     *      1. Flash loan the debt token amount
     *      2. Repay all Aave debt
     *      3. Withdraw collateral from Aave
     *      4. Swap collateral back to debt token via 1inch
     *      5. Pay Stratax fee
     *      6. Repay flash loan + premium
     *      7. Any leftover is supplied back to Aave or sent to user
     * @param _collateralToWithdraw Amount of collateral to withdraw from Aave (should include buffer for fees/slippage)
     * @param _debtAmount Total amount of debt to repay (from calculateUnwindParams)
     * @param _oneInchSwapData Encoded calldata from 1inch API for collateral → debt token swap
     * @param _minReturnAmount Minimum debt tokens expected from swap for slippage protection
     */
    function unwindPosition(
        uint256 _collateralToWithdraw,
        uint256 _debtAmount,
        bytes calldata _oneInchSwapData,
        uint256 _minReturnAmount
    ) external onlyOwner {
        UnwindParams memory params = UnwindParams({
            collateralToken: collateralToken,
            collateralToWithdraw: _collateralToWithdraw,
            debtToken: borrowToken,
            debtAmount: _debtAmount,
            oneInchSwapData: _oneInchSwapData,
            minReturnAmount: _minReturnAmount
        });

        bytes memory encodedParams = abi.encode(OperationType.UNWIND, msg.sender, params);

        // Initiate flash loan of the debt token to repay Aave
        aavePool.flashLoanSimple(address(this), address(borrowToken), _debtAmount, encodedParams, 0);
    }

    /**
     * @notice Callback function called by Aave Pool after receiving flash loan
     * @dev This function must be implemented to handle flash loans from Aave V3
     *      It routes to either _executeOpenOperation or _executeUnwindOperation based on OperationType
     * @param _asset The flash loaned asset address
     * @param _amount The flash loan amount received
     * @param _premium The Aave flash loan fee (typically 0.05%)
     * @param _initiator The address that initiated the flash loan (must be this contract)
     * @param _params Encoded parameters containing OperationType and operation-specific params
     * @return bool Returns true if operation succeeds, reverts otherwise
     */
    function executeOperation(
        address _asset,
        uint256 _amount,
        uint256 _premium,
        address _initiator,
        bytes calldata _params
    ) external nonReentrant returns (bool) {
        require(msg.sender == address(aavePool), "Caller must be Aave Pool");
        require(_initiator == address(this), "Initiator must be this contract");

        // Decode operation type
        OperationType opType = abi.decode(_params, (OperationType));

        if (opType == OperationType.OPEN) {
            return _executeOpenOperation(_asset, _amount, _premium, _params);
        } else {
            return _executeUnwindOperation(_asset, _amount, _premium, _params);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates the maximum theoretical leverage for a given LTV (without fees/margins)
     * @param _ltv The loan-to-value ratio with 4 decimals (e.g., 8000 = 80%)
     * @return maxLeverage The maximum leverage with 4 decimals (e.g., 50000 = 5x)
     */
    function getMaxLeverage(uint256 _ltv) public pure returns (uint256 maxLeverage) {
        require(_ltv > 0 && _ltv < StrataxCalculations.LTV_PRECISION, "Invalid LTV");

        // Maximum leverage = 1 / (1 - LTV)
        // With 4 decimal precision: maxLeverage = 10000 / (10000 - ltv)
        maxLeverage = (StrataxCalculations.LEVERAGE_PRECISION * StrataxCalculations.LEVERAGE_PRECISION)
            / (StrataxCalculations.LTV_PRECISION - _ltv);
    }

    /**
     * @notice Calculates the maximum theoretical leverage for a specific asset on Aave (without fees/margins)
     * @return maxLeverage The maximum leverage with 4 decimals (e.g., 50000 = 5x)
     */
    function getMaxLeverage() public view returns (uint256 maxLeverage) {
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(collateralToken);
        require(ltv > 0, "Asset not usable as collateral");

        return getMaxLeverage(ltv);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Internal function to calculate the amount of free collateral available for use in leverage calculations
     * @return freeCollateral The amount of collateral (in collateral token units)
     * that is not backing existing debt and can be considered "free" for leverage calculations
     */
    function _getFreeCollateral() internal view returns (uint256 freeCollateral) {
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(collateralToken);
        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        uint256 borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        require(borrowTokenPrice > 0, "Borrow token price must be > 0");
        require(collateralTokenPrice > 0, "Collateral token price must be > 0");
        // determine the amount of free collateral to use
        // consider the collateral in this contract and "free" collateral in the Aave position
        freeCollateral = _getFreeCollateral(collateralTokenPrice, borrowTokenPrice, ltv);
        return freeCollateral;
    }

    /**
     * @notice Internal function to calculate the amount of free collateral available for use in leverage calculations
     * @param _collateralTokenPrice The price of the collateral token in USD with 8 decimals
     * @param _borrowTokenPrice The price of the borrow token in USD with 8
     * decimals
     * @return freeCollateral The amount of collateral (in collateral token units)
     * that is not backing existing debt and can be considered "free" for leverage calculations
     */
    function _getFreeCollateral(uint256 _collateralTokenPrice, uint256 _borrowTokenPrice, uint256 _ltv)
        internal
        view
        returns (uint256 freeCollateral)
    {
        //get the address of the aToken for the collateral
        (address aTokenCollateral,,) = aaveDataProvider.getReserveTokensAddresses(collateralToken);
        uint256 aTokenBalance = IERC20(aTokenCollateral).balanceOf(address(this));

        //currently open debt
        (,, address variableDebtToken) = aaveDataProvider.getReserveTokensAddresses(borrowToken);
        uint256 debtTokenAmount = IERC20(variableDebtToken).balanceOf(address(this));

        uint256 collateralBackingDebt = ((debtTokenAmount) * _borrowTokenPrice * (10 ** collateralTokenDecimals))
            / (_collateralTokenPrice * (10 ** borrowTokenDecimals));
        require(_ltv > 0, "Invalid LTV");
        // Required collateral to back debt at the given LTV (rounded up for safety).
        collateralBackingDebt = (collateralBackingDebt * StrataxCalculations.LTV_PRECISION + _ltv - 1) / _ltv;

        //determine the free collateral to be considered
        if ((aTokenBalance) >= collateralBackingDebt) {
            freeCollateral = aTokenBalance - collateralBackingDebt;
        }
        return freeCollateral;
    }

    /**
     * @notice Internal function to handle opening a leveraged position via flash loan callback
     * @dev Executes the following steps:
     *      1. Calculate and pay Stratax fee
     *      2. Supply collateral (flash loan + user collateral) to Aave
     *      3. Borrow debt tokens from Aave
     *      4. Swap borrowed tokens to collateral token via 1inch
     *      5. Repay flash loan with swap proceeds
     *      6. Supply any leftover collateral back to Aave
     * @param _asset The flash loaned asset address (collateral token)
     * @param _amount The flash loan amount
     * @param _premium The Aave flash loan fee
     * @param _params Encoded parameters containing operation type and FlashLoanParams
     * @return bool Returns true if operation succeeds, reverts otherwise
     */
    function _executeOpenOperation(address _asset, uint256 _amount, uint256 _premium, bytes calldata _params)
        internal
        returns (bool)
    {
        (, address user, FlashLoanParams memory flashParams) =
            abi.decode(_params, (OperationType, address, FlashLoanParams));

        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(collateralToken);
        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        uint256 borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        require(borrowTokenPrice > 0, "Borrow token price must be > 0");
        require(collateralTokenPrice > 0, "Collateral token price must be > 0");

        uint256 freeCollateral = _getFreeCollateral(collateralTokenPrice, borrowTokenPrice, ltv);
        uint256 totalCollateral = flashParams.collateralAmount + freeCollateral;

        //1. Pay stratax fee
        uint256 strataxFeeAmount;
        {
            uint256 desiredLev = _calculateDesiredLeverage(_amount, totalCollateral);
            strataxFeeAmount = (_amount * IFeeCollector(feeCollector).strataxFee() * desiredLev)
                / (StrataxCalculations.FLASHLOAN_FEE_PREC * StrataxCalculations.LEVERAGE_PRECISION);
            IERC20(_asset).forceApprove(feeCollector, strataxFeeAmount);

            uint256 borrowAmountInUsd = (flashParams.borrowAmount * borrowTokenPrice) / (10 ** borrowTokenDecimals);

            IFeeCollector(feeCollector)
                .collectFeesAndRecordVolume(_asset, strataxFeeAmount, borrowToken, borrowAmountInUsd);
        }

        // Step 1: Supply collateral to Aave and subtract the fee from collateral
        uint256 totalCollateralAfterFee = _amount + totalCollateral - strataxFeeAmount;
        IERC20(_asset).forceApprove(address(aavePool), totalCollateralAfterFee);
        aavePool.supply(_asset, totalCollateralAfterFee, address(this), 0);

        // Step 2: Borrow, swap, and repay
        {
            uint256 prevBal = IERC20(flashParams.borrowToken).balanceOf(address(this));
            aavePool.borrow(flashParams.borrowToken, flashParams.borrowAmount, VARIABLE_DEBT, 0, address(this));

            (,,,,, uint256 health) = aavePool.getUserAccountData(address(this));

            IERC20(flashParams.borrowToken).forceApprove(address(oneInchRouter), flashParams.borrowAmount);
            uint256 returnAmt = _call1InchSwap(
                flashParams.oneInchSwapData,
                flashParams.borrowToken,
                flashParams.collateralToken,
                flashParams.minReturnAmount
            );

            require(
                IERC20(flashParams.borrowToken).balanceOf(address(this)) == prevBal, "Borrow token left in contract"
            );
            // at Max Leverage
            // healthfactor: 1043181989512082799
            //amount approved 2918_448040
            // amount requested 2924_209067
            // stratax fee: 5_761027
            // supose leftover amount: 9_463547

            uint256 totalDebt = _amount + _premium;
            require(returnAmt >= totalDebt, "Insufficient funds to repay flash loan");

            if (returnAmt > totalDebt) {
                uint256 leftover = returnAmt - totalDebt;
                IERC20(_asset).forceApprove(address(aavePool), leftover);

                aavePool.supply(_asset, leftover, address(this), 0);
            }

            IERC20(_asset).forceApprove(address(aavePool), totalDebt);
        }

        emit LeveragePositionCreated(user, _asset, flashParams.borrowToken, totalCollateral, flashParams.borrowAmount);

        return true;
    }

    /**
     * @notice Calculates the desired leverage from flash loan and collateral amounts
     * @dev Uses quadratic formula to reverse-engineer the leverage from calculateOpenParams
     * @param flashLoanAmount The flash loan amount used in the position
     * @param collateralAmount The original collateral amount provided by user
     * @return desiredLeverage The calculated desired leverage with 4 decimals
     */
    function _calculateDesiredLeverage(uint256 flashLoanAmount, uint256 collateralAmount)
        internal
        returns (uint256 desiredLeverage)
    {
        uint256 fee = IFeeCollector(feeCollector).strataxFee();
        fee = fee + flashLoanFeeBps;
        // FLASHLOAN_FEE_PREC == LEVERAGE_PREC

        // Handle edge case where fee is 0 (simple linear equation)
        if (fee == 0) {
            // flashLoanAmount = collateralAmount * (L - PREC) / PREC
            // Therefore: L = (flashLoanAmount * PREC / collateralAmount) + PREC
            return (flashLoanAmount * StrataxCalculations.FLASHLOAN_FEE_PREC) / collateralAmount
                + StrataxCalculations.FLASHLOAN_FEE_PREC;
        }

        // With fees, we need to solve a quadratic equation
        // Standard form: aL² + bL + c = 0
        // Using quadratic formula: L = (-b ± sqrt(b² - 4ac)) / 2a
        uint256 a = collateralAmount * fee; // precision: collateral + fee
        uint256 b = collateralAmount * (StrataxCalculations.FLASHLOAN_FEE_PREC - fee); // precision: collateral + fee
        uint256 c = (collateralAmount + flashLoanAmount) * StrataxCalculations.FLASHLOAN_FEE_PREC; // precision: collateral + fee

        // Calculate discriminant: b² - 4ac
        uint256 discriminant = b * b - 4 * a * c; // precision: (collateral + fee)²
        uint256 sqrtDiscriminant = sqrt(discriminant);

        // Take the positive root: L = (b - sqrt(discriminant)) * PREC / (2a)
        desiredLeverage = (b - sqrtDiscriminant) * StrataxCalculations.FLASHLOAN_FEE_PREC / (2 * a);
        return desiredLeverage;
    }

    /**
     * @notice Public wrapper for calculating desired leverage from flash loan and collateral amounts
     * @param _flashLoanAmount The flash loan amount used
     * @param _collateralAmount The original collateral amount
     * @return desiredLeverage The calculated leverage with 4 decimals (e.g., 30000 = 3x)
     */
    function calculateDesiredLeverage(uint256 _flashLoanAmount, uint256 _collateralAmount)
        public
        returns (uint256 desiredLeverage)
    {
        return desiredLeverage = _calculateDesiredLeverage(_flashLoanAmount, _collateralAmount);
    }

    /**
     * @notice Internal function to handle unwinding a leveraged position via flash loan callback
     * @dev Executes the following steps:
     *      1. Repay Aave debt with flash loaned tokens
     *      2. Withdraw collateral from Aave proportional to debt repaid
     *      3. Swap collateral to debt token via 1inch
     *      4. Calculate and pay Stratax fee
     *      5. Repay flash loan + premium
     *      6. Supply any leftover tokens back to Aave
     * @param _asset The flash loaned asset address (debt token)
     * @param _amount The flash loan amount (debt to repay)
     * @param _premium The Aave flash loan fee
     * @param _params Encoded parameters containing operation type and UnwindParams
     * @return bool Returns true if operation succeeds, reverts otherwise
     */
    function _executeUnwindOperation(address _asset, uint256 _amount, uint256 _premium, bytes calldata _params)
        internal
        returns (bool)
    {
        (, address user, UnwindParams memory unwindParams) = abi.decode(_params, (OperationType, address, UnwindParams));

        // Step 1: Repay the Aave debt using flash loaned tokens
        IERC20(_asset).forceApprove(address(aavePool), _amount);
        aavePool.repay(_asset, _amount, VARIABLE_DEBT, address(this));

        // Step 2: Calculate and withdraw only the collateral that backed the repaid debt
        uint256 withdrawnAmount;
        uint256 strataxFeeInDebtToken;
        uint256 debtTokenPrice;
        {
            // Get prices and decimals
            debtTokenPrice = IStrataxOracle(strataxOracle).getPrice(_asset);
            require(debtTokenPrice > 0, "Invalid prices");

            // Use the same fee logic as calculateUnwindParams, but collect in debt token from swap proceeds.
            strataxFeeInDebtToken =
                (_amount * IFeeCollector(feeCollector).strataxFee()) / StrataxCalculations.FLASHLOAN_FEE_PREC;

            withdrawnAmount =
                aavePool.withdraw(unwindParams.collateralToken, unwindParams.collateralToWithdraw, address(this));
        }

        // Step 3: Swap collateral to debt token to repay flash loan
        IERC20(unwindParams.collateralToken).forceApprove(address(oneInchRouter), withdrawnAmount);
        uint256 returnAmount = _call1InchSwap(
            unwindParams.oneInchSwapData, unwindParams.collateralToken, borrowToken, unwindParams.minReturnAmount
        );

        //4. Pay stratax fee
        // Step 5: Repay flash loan
        uint256 totalDebt = _amount + _premium;
        require(returnAmount >= totalDebt, "Insufficient funds to repay flash loan");

        // Supply any leftover tokens back to Aave
        // Note: There might be other positions open, so unwinding one position will increase the health factor
        uint256 leftoverAfterRepay = returnAmount - totalDebt;

        // Collect protocol fee from debt-token proceeds so swap allowance matches swap calldata amount.
        if (strataxFeeInDebtToken > 0) {
            require(leftoverAfterRepay >= strataxFeeInDebtToken, "Insufficient funds for stratax fee");
            IERC20(_asset).forceApprove(feeCollector, strataxFeeInDebtToken);

            uint256 borrowAmountInUsd = (_amount * debtTokenPrice) / (10 ** borrowTokenDecimals);
            IFeeCollector(feeCollector)
                .collectFeesAndRecordVolume(_asset, strataxFeeInDebtToken, _asset, borrowAmountInUsd);

            leftoverAfterRepay = leftoverAfterRepay - strataxFeeInDebtToken;
        }

        if (leftoverAfterRepay > 0) {
            IERC20(_asset).forceApprove(address(aavePool), leftoverAfterRepay);
            aavePool.supply(_asset, leftoverAfterRepay, address(this), 0);
        }

        // approve aave to retrive payment for the flash loan
        IERC20(_asset).forceApprove(address(aavePool), totalDebt);

        emit PositionUnwound(user, unwindParams.collateralToken, _asset, _amount, withdrawnAmount);

        return true;
    }

    event DEBUG(uint256 value, string description);

    /**
     * @notice Internal function to execute a token swap via 1inch aggregator with security checks
     * @dev Performs low-level call to 1inch router with pre-encoded swap data
     *      Includes multiple security validations:
     *      - Verifies function selector is whitelisted
     *      - Checks source token balance decreased
     *      - Verifies destination token balance increased
     *      - Validates dstReceiver is this contract (for swap function)
     * @param _swapParams Encoded calldata for the 1inch swap (from 1inch API)
     * @param _srcToken The source token being swapped from
     * @param _dstToken The destination token being swapped to
     * @param _minReturnAmount Minimum acceptable return amount for slippage protection
     * @return returnAmount Actual amount received from the swap
     */
    function _call1InchSwap(bytes memory _swapParams, address _srcToken, address _dstToken, uint256 _minReturnAmount)
        internal
        returns (uint256 returnAmount)
    {
        // 1. Verify calldata has minimum length for function selector
        require(_swapParams.length >= 4, "Invalid swap params length");

        // 2. Extract and verify function selector
        bytes4 selector;
        assembly {
            selector := mload(add(_swapParams, 32))
        }

        // Common 1inch V5/V6 Router function selectors
        bytes4 SWAP_SELECTOR = 0x12aa3caf; // swap(address executor, SwapDescription desc, bytes permit, bytes data)
        bytes4 UNOSWAP_SELECTOR = 0x0502b1c5; // unoswap(address srcToken, uint256 amount, uint256 minReturn, uint256[] pools)
        bytes4 UNOSWAPV3_SELECTOR = 0xbc80f1a8; // unoswapV3(uint256 amount, uint256 minReturn, uint256[] pools)
        bytes4 UNISWAPV3_SWAP_SELECTOR = 0xe449022e; // uniswapV3Swap(uint256 amount, uint256 minReturn, uint256[] pools)
        bytes4 CLIPPER_SWAP_SELECTOR = 0x84bd6d29; // clipperSwap(...)
        bytes4 FILL_ORDER_RFQTO_SELECTOR = 0x5a099843; // fillOrderRFQTo(...)
        bytes4 FILL_ORDER_RFQTO_WITH_MAKEPERMIT_SELECTOR = 0x70ccbd31; // fillOrderRFQToWithMakingAmount(...)
        bytes4 ETHERS_SWAP_SELECTOR = 0x07ed2379; // ethersSwap(...) - 1inch V6
        bytes4 UNISWAP_V3_SWAP_TO_SELECTOR = 0x83800a8e; // uniswapV3SwapTo(...) - 1inch V6

        require(
            selector == SWAP_SELECTOR || selector == UNOSWAP_SELECTOR || selector == UNOSWAPV3_SELECTOR
                || selector == UNISWAPV3_SWAP_SELECTOR || selector == CLIPPER_SWAP_SELECTOR
                || selector == FILL_ORDER_RFQTO_SELECTOR || selector == FILL_ORDER_RFQTO_WITH_MAKEPERMIT_SELECTOR
                || selector == ETHERS_SWAP_SELECTOR || selector == UNISWAP_V3_SWAP_TO_SELECTOR,
            "Invalid 1inch function selector"
        );

        // 3. For swap() function, decode and verify SwapDescription
        if (selector == SWAP_SELECTOR) {
            _verifySwapDescription(_swapParams, _srcToken, _dstToken);
        }

        // 4. Record source token balance before swap
        uint256 srcBalanceBefore = IERC20(_srcToken).balanceOf(address(this));
        require(srcBalanceBefore > 0, "No source token to swap");

        // 5. Record destination token balance before swap
        uint256 dstBalanceBefore = IERC20(_dstToken).balanceOf(address(this));

        // 6. Execute the 1inch swap using low-level call
        (bool success, bytes memory result) = address(oneInchRouter).call(_swapParams);
        require(success, "1inch swap failed");

        // 7. Verify source token balance decreased (tokens were spent)
        uint256 srcBalanceAfter = IERC20(_srcToken).balanceOf(address(this));
        require(srcBalanceAfter < srcBalanceBefore, "Source token not spent in swap");

        // 8. Verify destination token balance increased (tokens were received)
        uint256 dstBalanceAfter = IERC20(_dstToken).balanceOf(address(this));
        require(dstBalanceAfter > dstBalanceBefore, "Destination token not received");

        uint256 actualReturnAmount = dstBalanceAfter - dstBalanceBefore;

        // 9. Verify minimum return amount for slippage protection
        require(actualReturnAmount >= _minReturnAmount, "Insufficient return amount from swap");

        return actualReturnAmount;
    }

    /**
     * @notice Verifies the SwapDescription struct in 1inch swap calldata
     * @dev Decodes and validates srcToken, dstToken, and dstReceiver from swap() calldata
     *      SwapDescription struct layout (1inch V5/V6):
     *      - srcToken (address)
     *      - dstToken (address)
     *      - srcReceiver (address)
     *      - dstReceiver (address)
     *      - amount (uint256)
     *      - minReturnAmount (uint256)
     *      - flags (uint256)
     * @param _swapParams The encoded swap calldata
     * @param _expectedSrcToken Expected source token address
     * @param _expectedDstToken Expected destination token address
     */
    function _verifySwapDescription(bytes memory _swapParams, address _expectedSrcToken, address _expectedDstToken)
        internal
        view
    {
        require(_swapParams.length >= 228, "Calldata too short for swap()"); // Minimum length for swap function

        address srcToken;
        address dstToken;
        address dstReceiver;

        assembly {
            // Calldata layout for swap(address executor, SwapDescription desc, ...):
            // 0-3: selector (4 bytes)
            // 4-35: executor address (32 bytes)
            // 36-67: SwapDescription offset (32 bytes)
            // 68-99: permit offset (32 bytes)
            // 100-131: data offset (32 bytes)
            // 132-163: srcToken (32 bytes) - start of SwapDescription
            // 164-195: dstToken (32 bytes)
            // 196-227: srcReceiver (32 bytes)
            // 228-259: dstReceiver (32 bytes)

            let dataPtr := add(_swapParams, 32) // Skip length prefix
            srcToken := mload(add(dataPtr, 132)) // Offset 132 for srcToken
            dstToken := mload(add(dataPtr, 164)) // Offset 164 for dstToken
            dstReceiver := mload(add(dataPtr, 228)) // Offset 228 for dstReceiver
        }

        require(srcToken == _expectedSrcToken, "Source token mismatch in swap description");
        require(dstToken == _expectedDstToken, "Destination token mismatch in swap description");
        require(dstReceiver == address(this), "Invalid destination receiver - tokens must come to this contract");
    }

    /**
     * @notice Public function to calculate the max leverage while considering fees and safety margins
     * @dev uses binary search and should call this off chain to save gas
     * @return maxLeverage The actual leverage that can be achieved after fees
     */
    function getMaxAchievableLeverageBinary() public view returns (uint256 maxLeverage) {
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(collateralToken);
        require(ltv > 0, "Asset not collateralizable");

        uint256 effectiveLtv =
            (ltv * (borrowSafetyMargin - maxLeverageOffset)) / StrataxCalculations.BORROW_SAFETY_PRECISION;
        require(effectiveLtv > 0, "Invalid effective LTV");

        uint256 strataxFee = IFeeCollector(feeCollector).strataxFee();

        // Search range: [1x, theoretical max]
        uint256 low = StrataxCalculations.LEVERAGE_PRECISION;
        uint256 high = getMaxLeverage(ltv); // e.g. 1 / (1 - LTV)
        uint256 best = low;

        while (low <= high) {
            uint256 mid = low + (high - low) / 2;

            if (_isLeverageSafe(mid, effectiveLtv, strataxFee)) {
                best = mid;
                low = mid + 1;
            } else {
                high = mid - 1;
            }
        }

        return best;
    }

    /**
     * @notice Internal function to verify leverage is safe
     * @dev considers stratax fee and flashloan fee when verifying leverage
     * @param _leverage leverage of the position
     * @param _effectiveLtv This includes the borrowSafetyMargin
     * @param _strataxFee Strtax fee as a percent with 4 decimals of precision
     * @return isSafe whether the leverage is achievable
     */
    function _isLeverageSafe(uint256 _leverage, uint256 _effectiveLtv, uint256 _strataxFee)
        internal
        view
        returns (bool)
    {
        // Borrowed amount to reach leverage L:
        // borrowed = C * (L - 1)
        uint256 borrowed = (StrataxCalculations.BASE_COLLATERAL * (_leverage - StrataxCalculations.LEVERAGE_PRECISION))
            / StrataxCalculations.LEVERAGE_PRECISION;

        // Flash loan fee
        uint256 flashFee = (borrowed * flashLoanFeeBps) / StrataxCalculations.FLASHLOAN_FEE_PREC;

        uint256 totalDebt = borrowed + flashFee;

        // Stratax fee scales with notional × leverage
        // fee = C * L * strataxFee
        uint256 protocolFee = (StrataxCalculations.BASE_COLLATERAL * _leverage * _strataxFee)
            / (StrataxCalculations.LEVERAGE_PRECISION * StrataxCalculations.FLASHLOAN_FEE_PREC);

        // Effective collateral after protocol fee
        if (protocolFee >= StrataxCalculations.BASE_COLLATERAL) return false;

        uint256 effectiveCollateral = (StrataxCalculations.BASE_COLLATERAL + borrowed) - protocolFee;

        // Max borrow allowed by Aave LTV
        uint256 maxBorrow = (effectiveCollateral * _effectiveLtv) / (StrataxCalculations.FLASHLOAN_FEE_PREC);

        return totalDebt <= maxBorrow;
    }

    /*//////////////////////////////////////////////////////////////
                            View Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the owner of this Stratax position contract
     * @return The address of the owner (NFT holder)
     */
    function owner() public view returns (address) {
        return strataxPositionNft.ownerOf(tokenId);
    }

    /**
     * @notice public wrapper around the internal function
     * @dev considers stratax fee and flashloan fee when verifying leverage
     * @param _leverage leverage of the position
     * @param _effectiveLtv This includes the borrowSafetyMargin
     * @param _strataxFee Strtax fee as a percent with 4 decimals of precision
     * @return isSafe bool whether the supplied leverage is achievable
     */
    function isLeverageSafe(uint256 _leverage, uint256 _effectiveLtv, uint256 _strataxFee) public view returns (bool) {
        return _isLeverageSafe(_leverage, _effectiveLtv, _strataxFee);
    }

    /**
     * @notice Returns the collateral token address for this position
     * @return The address of the collateral token
     */
    function getCollateralTokenAddress() public view returns (address) {
        return address(collateralToken);
    }

    /**
     * @notice Returns the borrow token address for this position
     * @return The address of the borrow token
     */
    function getBorrowTokenAddress() public view returns (address) {
        return address(borrowToken);
    }

    /**
     * @notice Returns the amount of free collateral available in the position
     * @dev Free collateral is collateral not currently backing any debt
     * @return The amount of free collateral in collateral token units
     */
    function getFreeCollateral() public view returns (uint256) {
        return _getFreeCollateral();
    }

    /**
     * @notice Returns the amount of free collateral available given specific prices and LTV
     * @param _collateralTokenPrice Price of collateral token in USD with 8 decimals
     * @param _borrowTokenPrice Price of borrow token in USD with 8 decimals
     * @param _ltv The loan-to-value ratio with 4 decimals
     * @return The amount of free collateral in collateral token units
     */
    function getFreeCollateral(uint256 _collateralTokenPrice, uint256 _borrowTokenPrice, uint256 _ltv)
        public
        view
        returns (uint256)
    {
        return _getFreeCollateral(_collateralTokenPrice, _borrowTokenPrice, _ltv);
    }

    /**
     * @notice Returns the current leverage of the position
     * @dev Leverage = Total Collateral Value / Equity
     *      Where Equity = Total Collateral Value - Total Debt Value
     *      Uses StrataxOracle for price feeds (8 decimals)
     * @return currentLeverage The current leverage with 4 decimals (e.g., 30000 = 3x)
     *         Returns 0 if there is no position (no collateral)
     */
    function getCurrentLeverage() public view returns (uint256 currentLeverage) {
        // Get token addresses
        (address aTokenCollateral,,) = aaveDataProvider.getReserveTokensAddresses(collateralToken);

        //get borrow token addresses
        (,, address variableDebtToken) = aaveDataProvider.getReserveTokensAddresses(borrowToken);

        // Get token balances
        uint256 aTokenBalance = IERC20(aTokenCollateral).balanceOf(address(this));
        uint256 debtTokenAmount = IERC20(variableDebtToken).balanceOf(address(this));

        // If no collateral, return 0 leverage
        if (aTokenBalance == 0) {
            return 0;
        }

        // If no debt, leverage is 1x
        if (debtTokenAmount == 0) {
            return StrataxCalculations.LEVERAGE_PRECISION; // 10000 = 1x
        }

        // Get prices from oracle (8 decimals)
        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        uint256 borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        require(collateralTokenPrice > 0, "Collateral token price must be > 0");
        require(borrowTokenPrice > 0, "Borrow token price must be > 0");

        // Calculate total collateral value in USD (with 8 decimals)
        // totalCollateralValueUsd = (aTokenBalance * collateralPrice) / (10^collateralDecimals)
        uint256 totalCollateralValueUsd = (aTokenBalance * collateralTokenPrice) / (10 ** collateralTokenDecimals);

        // Calculate total debt value in USD (with 8 decimals)
        // totalDebtValueUsd = (debtTokenAmount * borrowPrice) / (10^borrowDecimals)
        uint256 totalDebtValueUsd = (debtTokenAmount * borrowTokenPrice) / (10 ** borrowTokenDecimals);

        // Leverage = Total Collateral / (Total Collateral - Total Debt)
        uint256 equity = totalCollateralValueUsd - totalDebtValueUsd;

        // Prevent division by zero (shouldn't happen if totalDebtValueUsd < totalCollateralValueUsd)
        require(equity > 0, "Invalid position: debt exceeds collateral");

        currentLeverage = (totalCollateralValueUsd * StrataxCalculations.LEVERAGE_PRECISION) / equity;

        return currentLeverage;
    }

    /**
     * @notice Returns the current position value in USD (collateral value - debt value)
     * @dev Uses StrataxOracle for price feeds (8 decimals)
     * @return positionValueUsd The current position value in USD with 8 decimals
     *         Returns 0 if position is underwater (debt value >= collateral value)
     */
    function getPositionUsdValue() public view returns (uint256 positionValueUsd) {
        // Get token addresses
        (address aTokenCollateral,,) = aaveDataProvider.getReserveTokensAddresses(collateralToken);
        (,, address variableDebtToken) = aaveDataProvider.getReserveTokensAddresses(borrowToken);

        // Get token balances
        uint256 aTokenBalance = IERC20(aTokenCollateral).balanceOf(address(this));
        uint256 debtTokenAmount = IERC20(variableDebtToken).balanceOf(address(this));

        // Get prices from oracle (8 decimals)
        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        uint256 borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        require(collateralTokenPrice > 0, "Collateral token price must be > 0");
        require(borrowTokenPrice > 0, "Borrow token price must be > 0");

        // Calculate total collateral value in USD (with 8 decimals)
        uint256 totalCollateralValueUsd = (aTokenBalance * collateralTokenPrice) / (10 ** collateralTokenDecimals);

        // Calculate total debt value in USD (with 8 decimals)
        uint256 totalDebtValueUsd = (debtTokenAmount * borrowTokenPrice) / (10 ** borrowTokenDecimals);

        if (totalCollateralValueUsd >= totalDebtValueUsd) {
            positionValueUsd = totalCollateralValueUsd - totalDebtValueUsd;
        } else {
            positionValueUsd = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    OnlyOwner and Utility Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Burns the position NFT and marks the position as closed
     * @dev Can only be called by the owner (NFT holder) and only if the position is safe to close
     *      Position must be fully unwound (no debt) before burning
     */
    function burnPosition(address newOwner) external onlyOwner {
        // Mark the position as burned in the NFT contract
        strataxPositionNft.burn(tokenId);
        // Update the burned token owner
        burnedTokenOwner = newOwner;
        isBurned = true;
        // Emit event for off-chain tracking
        emit PositionBurned(msg.sender, tokenId);
    }

    /**
     * @notice Emergency function to recover tokens sent to contract
     * @param _token The token address to recover
     * @param _amount The amount to recover
     */
    function recoverTokens(address _token, uint256 _amount) external onlyOwner {
        require(isBurned, "Position must be burned to recover tokens");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /**
     * @notice Supplies additional collateral to an existing position to improve health factor
     * @dev Transfers collateral from user and supplies it to Aave
     * @param _amount The amount of collateral to supply
     */
    function supplyCollateral(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Amount must be greater than zero");

        // Transfer collateral from user to contract
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), _amount);

        // Approve Aave pool to spend the collateral
        IERC20(collateralToken).forceApprove(address(aavePool), _amount);

        // Supply collateral to Aave
        aavePool.supply(collateralToken, _amount, address(this), 0);

        // Get health factor after supplying collateral
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));

        emit CollateralSupplied(msg.sender, address(collateralToken), _amount, healthFactor);
    }
    /**
     * @notice Withdraws collateral from Aave
     * @dev Withdraws collateral and sends it to the owner
     * @param _amount The amount of collateral to withdraw (use type(uint256).max to withdraw all)
     * @return amountWithdrawn The actual amount withdrawn
     */

    function withdrawCollateral(uint256 _amount) external onlyOwner returns (uint256 amountWithdrawn) {
        require(_amount > 0, "Amount must be greater than zero");

        // Withdraw collateral from Aave
        amountWithdrawn = aavePool.withdraw(collateralToken, _amount, msg.sender);

        // Get health factor after withdrawal
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        require(healthFactor > 1e18, "Withdrawal would make position unhealthy");

        return amountWithdrawn;
    }

    /**
     * @notice Borrows debt token from Aave against the supplied collateral
     * @dev Borrows debt token and sends it to the owner
     * @param _amount The amount of debt token to borrow
     */
    function borrowDebtToken(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Amount must be greater than zero");

        // Borrow from Aave
        aavePool.borrow(borrowToken, _amount, VARIABLE_DEBT, 0, address(this)); // Variable interest rate mode

        // Transfer borrowed tokens to owner
        IERC20(borrowToken).safeTransfer(msg.sender, _amount);

        // Get health factor after borrowing
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        require(healthFactor > 1e18, "Borrow would make position unhealthy");
    }

    /**
     * @notice Repays debt token to Aave
     * @dev Transfers debt token from user and repays to Aave
     * @param _amount The amount of debt token to repay (use type(uint256).max to repay all)
     * @return amountRepaid The actual amount repaid
     */
    function repayDebtToken(uint256 _amount) external onlyOwner returns (uint256 amountRepaid) {
        require(_amount > 0, "Amount must be greater than zero");

        // Transfer debt token from user to contract
        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), _amount);

        // Approve Aave pool to spend the debt token
        IERC20(borrowToken).forceApprove(address(aavePool), _amount);

        // Repay debt to Aave
        amountRepaid = aavePool.repay(borrowToken, _amount, VARIABLE_DEBT, address(this)); // Variable interest rate mode

        return amountRepaid;
    }

    /**
     * @notice Updates the cached flash loan fee from the Aave pool
     * @dev Fetches the current flash loan premium from Aave and updates the cached value
     *      Can only be called by the position owner
     */
    function updateFlashLoanFee() external onlyOwner {
        flashLoanFeeBps = aavePool.FLASHLOAN_PREMIUM_TOTAL();
        require(flashLoanFeeBps < StrataxCalculations.FLASHLOAN_FEE_PREC, "Fee must be < 100%");
    }

    /**
     * @notice Updates the 1inch router address
     * @dev Allows owner to update the 1inch router in case of upgrades or changes in the 1inch protocol
     * @param _newRouter The address of the new 1inch router
     */
    function update1InchRouter(address _newRouter) external onlyOwner {
        require(_newRouter != address(0), "Invalid router address");
        address oldRouter = address(oneInchRouter);
        oneInchRouter = IAggregationRouter(_newRouter);
        emit OneInchRouterUpdated(_newRouter, oldRouter);
    }

    /**
     * @notice Updates the maximum leverage offset used in max leverage calculations
     * @dev Allows owner to adjust the max leverage offset to be more or less conservative based on market conditions.
     *      The offset is used to reduce the effective LTV when calculating max leverage,
     *      providing a safety buffer to prevent positions from being too close to the liquidation threshold.
     *      The offset is expressed with 4 decimal precision (e.g., 75 = 0.75%).
     * @param _newOffset The new max leverage offset (must be <= 500, i.e., 5%)
     */
    function updateMaxLeverageOffset(uint256 _newOffset) external onlyOwner {
        require(_newOffset <= 500, "Max leverage offset too high"); // max 5% offset
        uint256 oldOffset = maxLeverageOffset;
        maxLeverageOffset = _newOffset;
        emit MaxLeverageOffsetUpdated(_newOffset, oldOffset);
    }

    /**
     * @notice Extracts the function selector from encoded calldata
     * @dev Useful for debugging and verifying 1inch swap data
     * @param _calldata The encoded calldata
     * @return selector The 4-byte function selector
     */
    function extractSelector(bytes memory _calldata) public pure returns (bytes4 selector) {
        require(_calldata.length >= 4, "Calldata too short");
        assembly {
            selector := mload(add(_calldata, 32))
        }
        return selector;
    }
}
