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
contract Stratax is Initializable {
    /*//////////////////////////////////////////////////////////////
                            TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/
    using SafeERC20 for IERC20;

    /// @notice Enum for flash loan operation types
    enum OperationType {
        /// @notice Opening a new leveraged position
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

    /// @notice Parameters for calculating leveraged position details
    struct TradeDetails {
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
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Constant for basis points calculations (100% = 10000)
    uint256 public constant FLASHLOAN_FEE_PREC = 1e4;

    /// @notice Precision used for price feeds (8 decimals)
    uint256 public constant PRICE_FEED_PREC = 1e8;

    /// @notice Precision for loan-to-value ratios (4 decimals, e.g., 8000 = 80%)
    uint256 public constant LTV_PRECISION = 1e4;

    /// @notice Precision for leverage calculations (4 decimals, e.g., 30000 = 3x)
    uint256 public constant LEVERAGE_PRECISION = 1e4;

    /// @notice Precision for borrow safety which (4 decimals, e.g., 30000 = 3x)
    uint256 public constant BORROW_SAFETY_PRECISION = 1e4;

    /// @notice tokenId which represents this contract in the StrataxPositionNft
    uint256 public tokenId;

    /// @notice Safety margin for borrow calculations (9900 = 99% of max LTV)
    /// @dev This ensures positions have a healthy buffer and don't immediately risk liquidation
    uint256 public borrowSafetyMargin; // 99% of max LTV for Aave collateral

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

    /// @notice Precision of the collateral token in storage for gas savings
    uint256 public collateralTokenPrecision;

    /// @notice Decimals of the borrow token
    uint256 public borrowTokenDecimals;

    /// @notice Address of the Stratax price oracle contract
    address public strataxOracle;

    /// @notice Address for the fee collector which takes a opening and closing fee
    address public feeCollector;

    /// @notice Contract owner address
    address public owner;

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

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts function access to contract owner only
    modifier onlyOwner() {
        require(msg.sender == strataxPositionNft.ownerOf(tokenId), "Not Owner");
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

        // Fetch and store token decimals
        collateralTokenDecimals = IERC20Metadata(params.collateralToken).decimals();
        collateralTokenPrecision = 10 ** collateralTokenDecimals;
        borrowTokenDecimals = IERC20Metadata(params.borrowToken).decimals();

        // Set borrow safety margin with default if not provided
        if (params.borrowSafetyMargin == 0) {
            borrowSafetyMargin = 9900; // Default to 99% of max LTV
        } else {
            require(params.borrowSafetyMargin < BORROW_SAFETY_PRECISION, "Invalid safety margin");
            borrowSafetyMargin = params.borrowSafetyMargin;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
    ) external returns (bool) {
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
     * @notice Sets the Stratax Oracle address
     * @param _strataxOracle The new oracle address
     */
    function setStrataxOracle(address _strataxOracle) external onlyOwner {
        require(_strataxOracle != address(0), "Invalid oracle address");
        strataxOracle = _strataxOracle;
    }

    /**
     * @notice Sets the flash loan fee in basis points
     * @dev updates the flash loan fee from Aave
     */
    function updateFlashLoanFee() external {
        flashLoanFeeBps = aavePool.FLASHLOAN_PREMIUM_TOTAL();
        //
        require(flashLoanFeeBps < FLASHLOAN_FEE_PREC, "Fee must be < 100%");
    }

    /**
     * @notice Emergency function to recover tokens sent to contract
     * @param _token The token address to recover
     * @param _amount The amount to recover
     */
    function recoverTokens(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /**
     * @notice Updates the owner address
     * @param _newOwner The new owner address
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid address");
        owner = _newOwner;
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
        aavePool.borrow(borrowToken, _amount, 2, 0, address(this)); // Variable interest rate mode

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
        amountRepaid = aavePool.repay(borrowToken, _amount, 2, address(this)); // Variable interest rate mode

        return amountRepaid;
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
        require(_collateralAmount > 0, "Collateral Cannot be Zero");
        // Transfer the user's collateral to the contract
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), _collateralAmount);

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
     * @notice Calculates the maximum theoretical leverage for a given LTV (without fees/margins)
     * @param _ltv The loan-to-value ratio with 4 decimals (e.g., 8000 = 80%)
     * @return maxLeverage The maximum leverage with 4 decimals (e.g., 50000 = 5x)
     */
    function getMaxLeverage(uint256 _ltv) public pure returns (uint256 maxLeverage) {
        require(_ltv > 0 && _ltv < LTV_PRECISION, "Invalid LTV");

        // Maximum leverage = 1 / (1 - LTV)
        // With 4 decimal precision: maxLeverage = 10000 / (10000 - ltv)
        maxLeverage = (LEVERAGE_PRECISION * LEVERAGE_PRECISION) / (LTV_PRECISION - _ltv);
    }

    /**
     * @notice Calculates the maximum theoretical leverage for a specific asset on Aave (without fees/margins)
     * @param _asset The address of the collateral asset
     * @return maxLeverage The maximum leverage with 4 decimals (e.g., 50000 = 5x)
     */
    function getMaxLeverage(address _asset) public view returns (uint256 maxLeverage) {
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(_asset);
        require(ltv > 0, "Asset not usable as collateral");

        return getMaxLeverage(ltv);
    }

    /**
     * @notice Calculates the flash loan and borrow amounts needed to achieve desired leverage
     * @param details TradeDetails struct containing:
     *        - desiredLeverage: The desired leverage multiplier with 4 decimals (e.g., 30000 = 3x)
     *        - collateralAmount: The amount of collateral the user will provide (in collateral token units)
     *        - collateralTokenPrice: Price of collateral token in USD with 8 decimals
     *        - borrowTokenPrice: Price of borrow token in USD with 8 decimals
     * @return flashLoanAmount The amount to flash loan (in collateral token units)
     * @return borrowAmount The amount to borrow from Aave (in borrow token units)
     * @dev for off-chain use
     */
    function calculateOpenParams(TradeDetails memory details)
        public
        view
        returns (uint256 flashLoanAmount, uint256 borrowAmount)
    {
        // Get LTV from Aave for the collateral token
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(collateralToken);
        require(ltv > 0, "Asset not usable as collateral");
        require(details.desiredLeverage >= LEVERAGE_PRECISION, "Leverage must be >= 1x");
        require(details.collateralAmount > 0, "Collateral must be > 0");

        // Calculate maximum theoretical leverage and validate desired leverage
        uint256 maxLeverage = getMaxLeverage(ltv);
        require(details.desiredLeverage <= maxLeverage, "Desired leverage exceeds maximum");

        //calculate the max leverage considering the flash loan fee, stratax fee, and safety margin (combination of nearing max Aave LTV and swap slippage)
        uint256 actualMaxLeverage = getMaxAchievableLeverageBinary();
        if (details.desiredLeverage > actualMaxLeverage) {
            details.desiredLeverage = actualMaxLeverage;
        }

        //stratax fee logic
        {
            //calculate the fee
            uint256 strataxFee =
                (details.collateralAmount * IFeeCollector(feeCollector).strataxFee() * details.desiredLeverage)
                    / (FLASHLOAN_FEE_PREC * LEVERAGE_PRECISION);

            // subtract the fee from the collateral
            details.collateralAmount = details.collateralAmount - strataxFee;
        }

        // If collateral token price is zero, fetch it from the oracle
        if (details.collateralTokenPrice == 0) {
            require(strataxOracle != address(0), "Oracle not set");
            details.collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        }
        require(details.collateralTokenPrice > 0, "Collateral token price must be > 0");

        // If borrow token price is zero, fetch it from the oracle
        if (details.borrowTokenPrice == 0) {
            require(strataxOracle != address(0), "Oracle not set");
            details.borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        }
        require(details.borrowTokenPrice > 0, "Borrow token price must be > 0");

        // Flash loan amount = collateral × (leverage - 1)
        // flashLoanAmount = C × (L - 1) / LEVERAGE_PRECISION
        flashLoanAmount =
            (details.collateralAmount * (details.desiredLeverage - LEVERAGE_PRECISION)) / LEVERAGE_PRECISION;

        // Total collateral to supply = user collateral + flash loan
        uint256 totalCollateral = details.collateralAmount + flashLoanAmount;

        // Calculate total collateral value in USD (with proper decimal handling)
        // totalCollateralValueUsd = (totalCollateral * collateralPrice) / (10^collateralDec)
        // Result is in USD with 8 decimals
        uint256 totalCollateralValueUsd =
            (totalCollateral * details.collateralTokenPrice) / (10 ** collateralTokenDecimals);

        // Calculate borrow value in USD (with 8 decimals)
        // Apply safety margin to ensure healthy position: borrowValueUsd = (totalCollateralValueUsd * ltv * borrowSafetyMargin) / (LTV_PRECISION * 10000)
        uint256 borrowValueUsd =
            (totalCollateralValueUsd * ltv * borrowSafetyMargin) / (LTV_PRECISION * BORROW_SAFETY_PRECISION);

        // Convert borrow value to borrow token amount
        // borrowAmount = (borrowValueUsd * 10^borrowTokenDec) / borrowTokenPrice
        borrowAmount = (borrowValueUsd * (10 ** borrowTokenDecimals)) / details.borrowTokenPrice;

        // Ensure borrow amount when swapped back covers flash loan + fee
        uint256 flashLoanFee = (flashLoanAmount * flashLoanFeeBps) / FLASHLOAN_FEE_PREC;
        uint256 minRequiredAfterSwap = flashLoanAmount + flashLoanFee;

        // Calculate the value of borrowed tokens in collateral token terms
        // borrowValueInCollateral = (borrowAmount * borrowPrice * 10^collateralDec) / (collateralPrice * 10^borrowDec)
        uint256 borrowValueInCollateral = (borrowAmount * details.borrowTokenPrice * (10 ** collateralTokenDecimals))
            / (details.collateralTokenPrice * (10 ** borrowTokenDecimals));

        // This will revert if we are getting to close to theoretical max leverage
        require(borrowValueInCollateral >= minRequiredAfterSwap, "Insufficient borrow to repay flash loan");

        return (flashLoanAmount, borrowAmount);
    }

    /**
     * @notice Calculates the amount of collateral to withdraw and debt to repay for unwinding a position
     * @param _debtToRepay the amount of debt to repay on the position reducing the position size
     * @return collateralToWithdraw The amount of collateral to withdraw from Aave (includes slippage buffer)
     * @return debtAmount The total debt amount to repay
     * @return strataxFee The Stratax protocol fee amount
     * @dev if the _debtTeRepay is equal to or more than the actual debt, the position will be fully closed
     */
    function calculateUnwindParams(uint256 _debtToRepay)
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
        strataxFee = (_debtToRepay * IFeeCollector(feeCollector).strataxFee()) / FLASHLOAN_FEE_PREC;
        uint256 flashLoanFeeAmount = (_debtToRepay * flashLoanFeeBps) / FLASHLOAN_FEE_PREC;
        collateralToWithdraw = (debtTokenPrice * (_debtToRepay + flashLoanFeeAmount) * 10 ** collateralTokenDecimals)
            / (collateralTokenPrice * 10 ** borrowTokenDecimals);

        // Account for 5% slippage in swap, we will re-supply the excess amount to aave
        collateralToWithdraw = (collateralToWithdraw * 1050) / 1000; // There should Always be enough collateral to unwind a position

        return (collateralToWithdraw, _debtToRepay, strataxFee);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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

        //1. Pay stratax fee
        uint256 strataxFeeAmount;
        {
            uint256 desiredLev = _calculateDesiredLeverage(_amount, flashParams.collateralAmount);
            strataxFeeAmount = (_amount * IFeeCollector(feeCollector).strataxFee() * desiredLev)
                / (FLASHLOAN_FEE_PREC * LEVERAGE_PRECISION);
            IERC20(_asset).forceApprove(feeCollector, strataxFeeAmount);
            IFeeCollector(feeCollector).collectFees(_asset, strataxFeeAmount);
        }
        // subtract the fee from the amount
        _amount = _amount - strataxFeeAmount;

        // Step 1: Supply collateral to Aave
        uint256 totalCollateral = _amount + flashParams.collateralAmount;
        IERC20(_asset).forceApprove(address(aavePool), totalCollateral);
        aavePool.supply(_asset, totalCollateral, address(this), 0);

        // Step 2: Borrow, swap, and repay
        {
            uint256 prevBal = IERC20(flashParams.borrowToken).balanceOf(address(this));
            aavePool.borrow(flashParams.borrowToken, flashParams.borrowAmount, 2, 0, address(this));

            IERC20(flashParams.borrowToken).forceApprove(address(oneInchRouter), flashParams.borrowAmount);
            uint256 returnAmt =
                _call1InchSwap(flashParams.oneInchSwapData, flashParams.borrowToken, flashParams.minReturnAmount);

            require(
                IERC20(flashParams.borrowToken).balanceOf(address(this)) == prevBal, "Borrow token left in contract"
            );

            uint256 totalDebt = _amount + _premium + strataxFeeAmount;
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
        view
        returns (uint256 desiredLeverage)
    {
        uint256 fee = IFeeCollector(feeCollector).strataxFee();
        // FLASHLOAN_FEE_PREC == LEVERAGE_PREC

        // Handle edge case where fee is 0 (simple linear equation)
        if (fee == 0) {
            // flashLoanAmount = collateralAmount * (L - PREC) / PREC
            // Therefore: L = (flashLoanAmount * PREC / collateralAmount) + PREC
            return (flashLoanAmount * FLASHLOAN_FEE_PREC) / collateralAmount + FLASHLOAN_FEE_PREC;
        }

        // With fees, we need to solve a quadratic equation
        // Standard form: aL² + bL + c = 0
        // Using quadratic formula: L = (-b ± sqrt(b² - 4ac)) / 2a

        uint256 a = collateralAmount * fee;
        uint256 b = collateralAmount * (FLASHLOAN_FEE_PREC + fee);
        uint256 c = (collateralAmount + flashLoanAmount) * FLASHLOAN_FEE_PREC;

        // Calculate discriminant: b² - 4ac
        uint256 discriminant = b * b - 4 * a * c;
        uint256 sqrtDiscriminant = sqrt(discriminant);

        // Take the positive root: L = (b - sqrt(discriminant)) * PREC / (2a)
        desiredLeverage = (b - sqrtDiscriminant) * FLASHLOAN_FEE_PREC / (2 * a);

        return desiredLeverage;
    }

    function calculateDesiredLeverage(uint256 _flashLoanAmount, uint256 _collateralAmount)
        public
        view
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
        aavePool.repay(_asset, _amount, 2, address(this));

        // Step 2: Calculate and withdraw only the collateral that backed the repaid debt
        uint256 withdrawnAmount;
        uint256 strataxFeeInCollateral;
        {
            // Get prices and decimals
            uint256 debtTokenPrice = IStrataxOracle(strataxOracle).getPrice(_asset);
            uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(unwindParams.collateralToken);
            require(debtTokenPrice > 0 && collateralTokenPrice > 0, "Invalid prices");

            //use the same logic when calculating the undwin params
            uint256 strataxFee = (_amount * IFeeCollector(feeCollector).strataxFee()) / FLASHLOAN_FEE_PREC;
            strataxFeeInCollateral = (debtTokenPrice * (strataxFee) * 10 ** collateralTokenDecimals)
                / (collateralTokenPrice * 10 ** borrowTokenDecimals);
            uint256 collateralToWithdraw = (debtTokenPrice * (_amount + _premium) * 10 ** collateralTokenDecimals)
                / (collateralTokenPrice * 10 ** borrowTokenDecimals);

            //account for swap slippage and add the fee for withdrawal
            collateralToWithdraw = (collateralToWithdraw * 1050) / 1000 + strataxFeeInCollateral; // 5% slippage

            withdrawnAmount = aavePool.withdraw(unwindParams.collateralToken, collateralToWithdraw, address(this));
            withdrawnAmount = withdrawnAmount - strataxFeeInCollateral;
        }

        // Step 3: Swap collateral to debt token to repay flash loan
        IERC20(unwindParams.collateralToken).forceApprove(address(oneInchRouter), withdrawnAmount);
        uint256 returnAmount = _call1InchSwap(unwindParams.oneInchSwapData, _asset, unwindParams.minReturnAmount);

        //4. Pay stratax fee
        {
            IERC20(collateralToken).forceApprove(feeCollector, strataxFeeInCollateral);
            IFeeCollector(feeCollector).collectFees(collateralToken, strataxFeeInCollateral);
        }

        // Step 5: Repay flash loan
        uint256 totalDebt = _amount + _premium;
        require(returnAmount >= totalDebt, "Insufficient funds to repay flash loan");

        // Supply any leftover tokens back to Aave
        // Note: There might be other positions open, so unwinding one position will increase the health factor
        if (returnAmount - totalDebt > 0) {
            IERC20(_asset).forceApprove(address(aavePool), returnAmount - totalDebt);
            aavePool.supply(_asset, returnAmount - totalDebt, address(this), 0);
        }

        // approve aave to retrive payment for the flash loan
        IERC20(_asset).forceApprove(address(aavePool), totalDebt);

        emit PositionUnwound(user, unwindParams.collateralToken, _asset, _amount, withdrawnAmount);

        return true;
    }

    /**
     * @notice Internal function to execute a token swap via 1inch aggregator
     * @dev Performs low-level call to 1inch router with pre-encoded swap data
     *      The swap parameters must be obtained from the 1inch API beforehand
     * @param _swapParams Encoded calldata for the 1inch swap (from 1inch API)
     * @param _asset Address of the asset being swapped to
     * @param _minReturnAmount Minimum acceptable return amount for slippage protection
     * @return returnAmount Actual amount received from the swap
     */
    function _call1InchSwap(bytes memory _swapParams, address _asset, uint256 _minReturnAmount)
        internal
        returns (uint256 returnAmount)
    {
        // Execute the 1inch swap using low-level call with the calldata from the API
        (bool success, bytes memory result) = address(oneInchRouter).call(_swapParams);
        require(success, "1inch swap failed");

        // Decode the return amount from the swap
        if (result.length > 0) {
            (returnAmount,) = abi.decode(result, (uint256, uint256));
        } else {
            // If no return data, check balance
            returnAmount = IERC20(_asset).balanceOf(address(this));
        }
        // Sanity check
        require(returnAmount >= _minReturnAmount, "Insufficient return amount from swap");
        return returnAmount;
    }

    uint256 constant BASE_COLLATERAL = 1e18; // virtual unit

    /**
     * @notice Public function to calculate the max leverage while considering fees and safety margins
     * @dev uses binary search and should call this off chain to save gas
     * @return maxLeverage The actual leverage that can be achieved after fees
     */
    function getMaxAchievableLeverageBinary() public view returns (uint256 maxLeverage) {
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(collateralToken);
        require(ltv > 0, "Asset not collateralizable");

        uint256 effectiveLtv = (ltv * borrowSafetyMargin) / BORROW_SAFETY_PRECISION;
        require(effectiveLtv > 0, "Invalid effective LTV");

        uint256 strataxFee = IFeeCollector(feeCollector).strataxFee();

        // Search range: [1x, theoretical max]
        uint256 low = LEVERAGE_PRECISION;
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
        uint256 borrowed = (BASE_COLLATERAL * (_leverage - LEVERAGE_PRECISION)) / LEVERAGE_PRECISION;

        // Flash loan fee
        uint256 flashFee = (borrowed * flashLoanFeeBps) / FLASHLOAN_FEE_PREC;

        uint256 totalDebt = borrowed + flashFee;

        // Stratax fee scales with notional × leverage
        // fee = C * L * strataxFee
        uint256 protocolFee = (BASE_COLLATERAL * _leverage * _strataxFee) / (LEVERAGE_PRECISION * FLASHLOAN_FEE_PREC);

        // Effective collateral after protocol fee
        if (protocolFee >= BASE_COLLATERAL) return false;

        uint256 effectiveCollateral = (BASE_COLLATERAL + borrowed) - protocolFee;

        // Max borrow allowed by Aave LTV
        uint256 maxBorrow = (effectiveCollateral * _effectiveLtv) / (FLASHLOAN_FEE_PREC);

        return totalDebt <= maxBorrow;
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

    function getCollateralTokenAddress() public view returns (address) {
        return address(collateralToken);
    }

    function getBorrowTokenAddress() public view returns (address) {
        return address(borrowToken);
    }
}
