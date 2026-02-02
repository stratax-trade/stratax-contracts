// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13; // /Users/marquisharris/work/banken/stratax/frontend/

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPool} from "./interfaces/external/IPool.sol";
import {IAggregationRouter} from "./interfaces/external/IAggregationRouter.sol";
import {IProtocolDataProvider} from "./interfaces/external/IProtocolDataProvider.sol";
import {IStrataxOracle} from "./interfaces/internal/IStrataxOracle.sol";
import {IStrataxPositionNft} from "./interfaces/internal/IStrataxPositionNft.sol";
import {IFeeCollector} from "./interfaces/internal/IFeeCollector.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Stratax is Initializable {
    /*//////////////////////////////////////////////////////////////
                            TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

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
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Constant for basis points calculations (100% = 10000)
    uint256 public constant FLASHLOAN_FEE_PREC = 10_000;

    /// @notice Precision used for price feeds (8 decimals)
    uint256 public constant PRICE_FEED_PREC = 1e8;

    /// @notice Precision for loan-to-value ratios (4 decimals, e.g., 8000 = 80%)
    uint256 public constant LTV_PRECISION = 1e4;

    /// @notice Precision for leverage calculations (4 decimals, e.g., 30000 = 3x)
    uint256 public constant LEVERAGE_PRECISION = 1e4;

    /// @notice Safety margin for borrow calculations (9800 = 98% of max LTV)
    /// @dev This ensures positions have a healthy buffer and don't immediately risk liquidation
    uint256 public constant BORROW_SAFETY_MARGIN = 9800; // 98% of max

    IStrataxPositionNft public strataxPositionNft;
    uint256 public tokenId;

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

    uint256 public collateralTokenPrecision;

    /// @notice Decimals of the borrow token
    uint256 public borrowTokenDecimals;

    /// @notice Address of the Stratax price oracle contract
    address public strataxOracle;

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
        //require(msg.sender == owner, "Not owner");
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
        collateralTokenDecimals = IERC20(params.collateralToken).decimals();
        collateralTokenPrecision = 10 ** collateralTokenDecimals;
        borrowTokenDecimals = IERC20(params.borrowToken).decimals();
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Callback function called by Aave after receiving flash loan
     * @param _asset The flash loaned asset address
     * @param _amount The flash loan amount
     * @param _premium The flash loan fee
     * @param _initiator The initiator of the flash loan
     * @param _params Encoded parameters for the operation
     * @return bool Returns true if operation succeeds
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
     * @notice Unwinds a leveraged position by:
     * 1. Taking a flash loan of the debt token
     * 2. Repaying the Aave debt
     * 3. Withdrawing all collateral from Aave
     * 4. Swapping collateral back to debt token
     * 5. Repaying the flash loan
     * @param _collateralToWithdraw The amount of collateral to withdraw from Aave
     * @param _debtAmount The amount of debt to repay
     * @param _oneInchSwapData The calldata from 1inch API to swap collateral back to debt token
     * @param _minReturnAmount Minimum amount of debt token expected from swap (slippage protection)
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
        aavePool.flashLoanSimple(address(this), borrowToken, _debtAmount, encodedParams, 0);
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
     * @param _flashLoanFeeBps The flash loan fee in basis points (e.g., 9 = 0.09%)
     */
    function setFlashLoanFee(uint256 _flashLoanFeeBps) external onlyOwner {
        require(_flashLoanFeeBps < FLASHLOAN_FEE_PREC, "Fee must be < 100%");
        flashLoanFeeBps = _flashLoanFeeBps;
    }

    /**
     * @notice Emergency function to recover tokens sent to contract
     * @param _token The token address to recover
     * @param _amount The amount to recover
     */
    function recoverTokens(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).transfer(msg.sender, _amount);
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
        IERC20(collateralToken).transferFrom(msg.sender, address(this), _amount);

        // Approve Aave pool to spend the collateral
        IERC20(collateralToken).approve(address(aavePool), _amount);

        // Supply collateral to Aave
        aavePool.supply(collateralToken, _amount, address(this), 0);

        // Get health factor after supplying collateral
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));

        emit CollateralSupplied(msg.sender, collateralToken, _amount, healthFactor);
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
        IERC20(borrowToken).transfer(msg.sender, _amount);

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
        IERC20(borrowToken).transferFrom(msg.sender, address(this), _amount);

        // Approve Aave pool to spend the debt token
        IERC20(borrowToken).approve(address(aavePool), _amount);

        // Repay debt to Aave
        amountRepaid = aavePool.repay(borrowToken, _amount, 2, address(this)); // Variable interest rate mode

        return amountRepaid;
    }
    /*//////////////////////////////////////////////////////////////
                        PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a leveraged position by:
     * 1. Taking a flash loan
     * 2. Supplying flash loan + user's extra amount as collateral
     * 3. Borrowing against the collateral
     * 4. Swapping borrowed tokens via 1inch
     * 5. Repaying flash loan with swap proceeds
     * @param _flashLoanAmount The amount to flash loan
     * @param _collateralAmount Additional amount from user to supply as collateral
     * @param _borrowAmount The amount to borrow from Aave
     * @param _oneInchSwapData The calldata from 1inch API to swap borrowed token back to flash loan token
     * @param _minReturnAmount Minimum amount expected from swap (slippage protection)
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
        IERC20(collateralToken).transferFrom(msg.sender, address(this), _collateralAmount);

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
        aavePool.flashLoanSimple(address(this), collateralToken, _flashLoanAmount, encodedParams, 0);
    }

    /**
     * @notice Calculates the maximum theoretical leverage for a given LTV
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
     * @notice Calculates the maximum theoretical leverage for a specific asset on Aave
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

        //stratax fee logic
        {
            //calculate the fee
            uint256 strataxFee = (
                details.collateralAmount * IFeeCollector(feeCollector).strataxFee() * details.desiredLeverage
            ) / FLASHLOAN_FEE_PREC;

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

        // Calculate maximum theoretical leverage and validate desired leverage
        uint256 maxLeverage = getMaxLeverage(ltv);
        require(details.desiredLeverage <= maxLeverage, "Desired leverage exceeds maximum");

        // Flash loan amount = collateral × (leverage - 1)
        // flashLoanAmount = C × (L - 1) / LEVERAGE_PRECISION
        flashLoanAmount =
            (details.collateralAmount * (details.desiredLeverage - LEVERAGE_PRECISION)) / LEVERAGE_PRECISION;

        // Total collateral to supply = user collateral + flash loan
        uint256 totalCollateral = details.collateralAmount + flashLoanAmount;

        // Calculate total collateral value in USD (with proper decimal handling)
        // totalCollateralValueUSD = (totalCollateral * collateralPrice) / (10^collateralDec)
        // Result is in USD with 8 decimals
        uint256 totalCollateralValueUSD =
            (totalCollateral * details.collateralTokenPrice) / (10 ** collateralTokenDecimals);

        // Calculate borrow value in USD (with 8 decimals)
        // Apply safety margin to ensure healthy position: borrowValueUSD = (totalCollateralValueUSD * ltv * BORROW_SAFETY_MARGIN) / (LTV_PRECISION * 10000)
        uint256 borrowValueUSD = (totalCollateralValueUSD * ltv * BORROW_SAFETY_MARGIN) / (LTV_PRECISION * 10000);

        // Convert borrow value to borrow token amount
        // borrowAmount = (borrowValueUSD * 10^borrowTokenDec) / borrowTokenPrice
        borrowAmount = (borrowValueUSD * (10 ** borrowTokenDecimals)) / details.borrowTokenPrice;

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
     * @return collateralToWithdraw The amount of collateral to withdraw from Aave
     * @return debtAmount The total debt amount to repay
     */
    function calculateUnwindParams() public view returns (uint256 collateralToWithdraw, uint256 debtAmount) {
        // Get the address of the debt token
        (,, address debtToken) = aaveDataProvider.getReserveTokensAddresses(borrowToken);
        debtAmount = IERC20(debtToken).balanceOf(address(this));
        uint256 debtTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        uint256 strataxFee = (debtAmount * IFeeCollector(feeCollector).strataxFee()) / FLASHLOAN_FEE_PREC;
        uint256 flashLoanFeeAmount = (debtAmount * flashLoanFeeBps) / FLASHLOAN_FEE_PREC;
        collateralToWithdraw = (
            debtTokenPrice * (debtAmount + flashLoanFeeAmount + strataxFee) * 10 ** collateralTokenDecimals
        ) / (collateralTokenPrice * 10 ** borrowTokenDecimals);

        // Account for 5% slippage in swap
        collateralToWithdraw = (collateralToWithdraw * 1050) / 1000; // There should Always be enough collateral to unwind a position

        return (collateralToWithdraw, debtAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to handle opening a leveraged position
     * @dev Executes the flash loan callback logic for opening positions
     * @param _asset The flash loaned asset address
     * @param _amount The flash loan amount
     * @param _premium The flash loan fee
     * @param _params Encoded parameters containing operation type and FlashLoanParams
     * @return bool Returns true if operation succeeds
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
            IERC20(_asset).approve(feeCollector, strataxFeeAmount);
            IFeeCollector(feeCollector).collectFees(_asset, strataxFeeAmount);
        }
        // subtract the fee from the amount
        _amount = _amount - strataxFeeAmount;

        // Step 1: Supply collateral to Aave
        uint256 totalCollateral = _amount + flashParams.collateralAmount;
        IERC20(_asset).approve(address(aavePool), totalCollateral);
        aavePool.supply(_asset, totalCollateral, address(this), 0);

        // Step 2: Borrow, swap, and repay
        uint256 healthFactor;
        {
            uint256 prevBal = IERC20(flashParams.borrowToken).balanceOf(address(this));
            aavePool.borrow(flashParams.borrowToken, flashParams.borrowAmount, 2, 0, address(this));

            IERC20(flashParams.borrowToken).approve(address(oneInchRouter), flashParams.borrowAmount);
            uint256 returnAmt =
                _call1InchSwap(flashParams.oneInchSwapData, flashParams.borrowToken, flashParams.minReturnAmount);

            require(
                IERC20(flashParams.borrowToken).balanceOf(address(this)) == prevBal, "Borrow token left in contract"
            );

            uint256 totalDebt = _amount + _premium;
            require(returnAmt >= totalDebt, "Insufficient funds to repay flash loan");

            if (returnAmt > totalDebt) {
                uint256 leftover = returnAmt - totalDebt;
                IERC20(_asset).approve(address(aavePool), leftover);
                aavePool.supply(_asset, leftover, address(this), 0);
            }

            IERC20(_asset).approve(address(aavePool), totalDebt);
            (,,,,, healthFactor) = aavePool.getUserAccountData(address(this));
        }

        require(healthFactor > 1e18, "Position health factor too low");

        emit LeveragePositionCreated(
            user, _asset, flashParams.borrowToken, totalCollateral, flashParams.borrowAmount, healthFactor
        );

        return true;
    }

    /**
     * @notice Calculates the desired leverage based on flash loan amount and collateral
     * @dev Reverses the calculation from calculateOpenParams
     * @param flashLoanAmount The amount that was flash loaned
     * @param collateralAmount The original collateral amount provided by user
     * @return desiredLeverage The calculated desired leverage with 4 decimals
     */
    function _calculateDesiredLeverage(uint256 flashLoanAmount, uint256 collateralAmount)
        internal
        view
        returns (uint256 desiredLeverage)
    {
        // From calculateOpenParams logic:
        // strataxFee = (collateralAmount * fee * desiredLeverage) / FLASHLOAN_FEE_PREC
        // collateralAfterFee = collateralAmount - strataxFee
        // flashLoanAmount = (collateralAfterFee * (desiredLeverage - LEVERAGE_PRECISION)) / LEVERAGE_PRECISION
        //
        // Solving for desiredLeverage:
        // Let F = strataxFee rate, C = collateralAmount, L = desiredLeverage, FL = flashLoanAmount
        // collateralAfterFee = C - (C * F * L / FLASHLOAN_FEE_PREC) = C * (1 - F * L / FLASHLOAN_FEE_PREC)
        // FL = [C * (1 - F * L / FLASHLOAN_FEE_PREC) * (L - LEVERAGE_PRECISION)] / LEVERAGE_PRECISION
        //
        // Simplifying (where PREC = FLASHLOAN_FEE_PREC = LEVERAGE_PRECISION = 10000):
        // FL * PREC = C * (1 - F * L / PREC) * (L - PREC)
        // FL * PREC = C * (PREC - F * L) * (L - PREC) / PREC
        // FL * PREC^2 = C * (PREC - F * L) * (L - PREC)
        // FL * PREC^2 = C * (PREC * L - PREC^2 - F * L^2 + F * L * PREC)
        // FL * PREC^2 = C * (-F * L^2 + L * (PREC + F * PREC) - PREC^2)
        // 0 = -C * F * L^2 + C * L * (PREC + F * PREC) - C * PREC^2 - FL * PREC^2
        // C * F * L^2 - C * L * (PREC + F * PREC) + C * PREC^2 + FL * PREC^2 = 0
        //
        // Using quadratic formula: L = [b ± sqrt(b^2 - 4ac)] / 2a
        // where: a = C * F
        //        b = -C * (PREC + F * PREC)
        //        c = C * PREC^2 + FL * PREC^2

        uint256 fee = IFeeCollector(feeCollector).strataxFee();
        uint256 PREC = FLASHLOAN_FEE_PREC; // = LEVERAGE_PRECISION = 10000

        // Handle edge case where fee is 0
        if (fee == 0) {
            // Simple case: flashLoanAmount = collateralAmount * (L - PREC) / PREC
            // L = (flashLoanAmount * PREC / collateralAmount) + PREC
            return (flashLoanAmount * PREC) / collateralAmount + PREC;
        }

        // Quadratic coefficients (scaled to avoid overflow)
        uint256 a = collateralAmount * fee; // precision = collateral + fee
        uint256 b = collateralAmount * (PREC + fee * PREC / PREC); // = collateralAmount * (PREC + fee). // precision = collateral + fee
        //uint256 c = (collateralAmount + flashLoanAmount) * PREC * PREC; // precision = collateral + fee + fee <-- is this right?
        uint256 c = (collateralAmount + flashLoanAmount) * PREC; // @notice removed the PREC multiplication at the end

        // Calculate discriminant: b^2 - 4ac
        uint256 discriminant = b * b - 4 * a * c / PREC; // Divide by PREC to keep scale manageable
        //@note update decrease the precision of the discriminant
        discriminant = discriminant / (PREC * collateralTokenPrecision); // discrimnant precision should be (collateral + fee)

        //precision tracking notes
        /* 
        original:
        (2*collateral + 2* fee) - ((collateral + fee) + (collateral + fee + fee))
        thus, discriminant is not valid since the precision is not the same you cannot add
        
        updated:
        (2*collateral + 2* fee) - ((collateral + fee) + (collateral + fee))
        each side of the subtraction has the same precision so it is safe to subtract
        

        disctriminant precision = (2*collateral + 2* fee)
        i.e. collateral has 18 decimals and fee has 4
        the discriminant has 2(18) + 2(4) = 44 decimals

        */

        // Take positive root: L = (b + sqrt(discriminant)) / (2a)
        uint256 sqrtDiscriminant = _sqrt(discriminant);
        desiredLeverage = (b + sqrtDiscriminant) * PREC / (2 * a); // this should be correct after updated code

        return desiredLeverage;
    }

    /**
     * @notice Calculates square root using Babylonian method
     * @param x The number to calculate square root of
     * @return y The square root
     * @dev not constant time
     */
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _payStrataxFee(address _token, uint256 _tradeSize, uint256 _desiredLeverage)
        internal
        returns (uint256 feeAmount)
    {
        feeAmount = (_tradeSize * IFeeCollector(feeCollector).strataxFee() * _desiredLeverage)
            / (FLASHLOAN_FEE_PREC * LEVERAGE_PRECISION);
        IERC20(_token).approve(feeCollector, feeAmount);
        IFeeCollector(feeCollector).collectFees(_token, feeAmount);
        return feeAmount;
    }

    /**
     * @notice Internal function to handle unwinding a leveraged position
     * @dev Executes the flash loan callback logic for unwinding positions
     * @param _asset The flash loaned asset address
     * @param _amount The flash loan amount
     * @param _premium The flash loan fee
     * @param _params Encoded parameters containing operation type and UnwindParams
     * @return bool Returns true if operation succeeds
     */
    function _executeUnwindOperation(address _asset, uint256 _amount, uint256 _premium, bytes calldata _params)
        internal
        returns (bool)
    {
        (, address user, UnwindParams memory unwindParams) = abi.decode(_params, (OperationType, address, UnwindParams));

        // Step 1: Repay the Aave debt using flash loaned tokens
        IERC20(_asset).approve(address(aavePool), _amount);
        aavePool.repay(_asset, _amount, 2, address(this));

        // Step 2: Calculate and withdraw only the collateral that backed the repaid debt
        uint256 withdrawnAmount;
        {
            // Get LTV from Aave for the collateral token
            (,, uint256 liqThreshold,,,,,,,) =
                aaveDataProvider.getReserveConfigurationData(unwindParams.collateralToken);

            // Get prices and decimals
            uint256 debtTokenPrice = IStrataxOracle(strataxOracle).getPrice(_asset);
            uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(unwindParams.collateralToken);
            require(debtTokenPrice > 0 && collateralTokenPrice > 0, "Invalid prices");

            // Calculate collateral to withdraw: (debtAmount * debtPrice * collateralDec * LTV_PRECISION) / (collateralPrice * debtDec * ltv)
            uint256 collateralToWithdraw = (
                _amount * debtTokenPrice * (10 ** IERC20(unwindParams.collateralToken).decimals()) * LTV_PRECISION
            ) / (collateralTokenPrice * (10 ** IERC20(_asset).decimals()) * liqThreshold);

            withdrawnAmount = aavePool.withdraw(unwindParams.collateralToken, collateralToWithdraw, address(this));
        }

        // Step 3: Swap collateral to debt token to repay flash loan
        IERC20(unwindParams.collateralToken).approve(address(oneInchRouter), withdrawnAmount);
        uint256 returnAmount = _call1InchSwap(unwindParams.oneInchSwapData, _asset, unwindParams.minReturnAmount);

        //4. Pay stratax fee
        uint256 strataxFeeAmount;
        {
            uint256 desiredLev = _calculateDesiredLeverage(_amount, unwindParams.collateralToWithdraw);
            strataxFeeAmount = (_amount * IFeeCollector(feeCollector).strataxFee() * desiredLev)
                / (FLASHLOAN_FEE_PREC * LEVERAGE_PRECISION);
            IERC20(_asset).approve(feeCollector, strataxFeeAmount);
            IFeeCollector(feeCollector).collectFees(_asset, strataxFeeAmount);
        }

        // Step 5: Repay flash loan
        uint256 totalDebt = _amount + _premium + strataxFeeAmount;
        require(returnAmount >= totalDebt, "Insufficient funds to repay flash loan");

        // Supply any leftover tokens back to Aave
        // Note: There might be other positions open, so unwinding one position will increase the health factor
        if (returnAmount - totalDebt > 0) {
            IERC20(_asset).approve(address(aavePool), returnAmount - totalDebt);
            aavePool.supply(_asset, returnAmount - totalDebt, address(this), 0);
        }

        IERC20(_asset).approve(address(aavePool), totalDebt);

        emit PositionUnwound(user, unwindParams.collateralToken, _asset, _amount, withdrawnAmount);

        return true;
    }

    /**
     * @notice Internal function to execute a token swap via 1inch
     * @dev Performs low-level call to 1inch router and validates return amount
     * @param _swapParams Encoded calldata for the 1inch swap
     * @param _asset Address of the asset being swapped to
     * @param _minReturnAmount Minimum acceptable return amount (slippage protection)
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
}
