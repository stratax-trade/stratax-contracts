// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPool} from "../../interfaces/external/IPool.sol";
import {IProtocolDataProvider} from "../../interfaces/external/IProtocolDataProvider.sol";
import {IUniswapV3SwapRouter} from "../../interfaces/external/IUniswapV3SwapRouter.sol";
import {IStrataxOracle} from "../../interfaces/internal/IStrataxOracle.sol";
import {IStrataxPositionNft} from "../../interfaces/internal/IStrataxPositionNft.sol";
import {IFeeCollector} from "../../interfaces/internal/IFeeCollector.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {StrataxCalculations} from "../../libraries/StrataxCalculations.sol";
import {StrataxAaveLib} from "../../libraries/lending/StrataxAaveLib.sol";
import {StrataxUniswapLib} from "../../libraries/swapping/StrataxUniswapLib.sol";
import {StrataxCoreLib} from "../../libraries/stratax/StrataxCoreLib.sol";
import {StrataxAaveUniswapCombinedLib} from "../../libraries/combined/StrataxAaveUniswapCombinedLib.sol";

/**
 * @title Stratax_Aave_Uniswap
 * @notice A Uniswap-based leveraged position contract for Stratax.
 * @dev Uses Aave flash loans and Uniswap V3 exactInputSingle swaps.
 *      Opening params are computed internally from desired leverage.
 */
contract Stratax_Aave_Uniswap is Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    enum OperationType {
        OPEN,
        UNWIND
    }

    struct OpenParams {
        address collateralToken;
        uint256 collateralAmount;
        address borrowToken;
        uint256 borrowAmount;
        uint256 strataxFeeAmount;
        uint24 poolFee;
        uint256 minReturnAmount;
    }

    struct UnwindParams {
        address collateralToken;
        uint256 collateralToWithdraw;
        address debtToken;
        uint256 debtAmount;
        uint24 poolFee;
        uint256 minReturnAmount;
    }

    uint256 public constant VARIABLE_DEBT = 2;
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 50;

    uint256 public tokenId;
    bool public isBurned;
    address public burnedTokenOwner;

    uint256 public borrowSafetyMargin;
    uint256 public maxLeverageOffset;

    IStrataxPositionNft public strataxPositionNft;
    IPool public aavePool;
    IProtocolDataProvider public aaveDataProvider;
    IUniswapV3SwapRouter public uniswapRouter;

    address public collateralToken;
    address public borrowToken;

    uint256 public collateralTokenDecimals;
    uint256 public borrowTokenDecimals;

    address public strataxOracle;
    address public feeCollector;

    uint256 public flashLoanFeeBps;

    uint256[50] private __gap;

    event LeveragePositionCreated(
        address indexed user,
        address collateralToken,
        address borrowedToken,
        uint256 totalCollateralSupplied,
        uint256 borrowedAmount
    );
    event PositionUnwound(
        address indexed user, address collateralToken, address debtToken, uint256 debtRepaid, uint256 collateralReturned
    );
    event CollateralSupplied(address indexed user, address collateralToken, uint256 amount, uint256 healthFactor);
    event CollateralWithdrawn(address indexed user, address collateralToken, uint256 amount, uint256 healthFactor);
    event PositionBurned(address indexed user, uint256 tokenId);
    event FlashLoanFeeUpdated(uint256 newFeeBps, uint256 oldFeeBps);
    event BorrowSafetyMarginUpdated(uint256 newMargin, uint256 oldMargin);
    event MaxLeverageOffsetUpdated(uint256 newOffset, uint256 oldOffset);
    event UniswapRouterUpdated(address newRouter, address oldRouter);

    modifier onlyOwner() {
        if (isBurned) {
            require(msg.sender == burnedTokenOwner, "Not Owner");
        } else {
            require(msg.sender == strataxPositionNft.ownerOf(tokenId), "Not Owner");
        }
        _;
    }

    function initialize(
        StrataxAaveLib.PositionInitParams calldata lendingParams,
        StrataxUniswapLib.InitParams calldata swapParams,
        StrataxCoreLib.InitParams calldata strataxParams
    ) external initializer {
        require(swapParams.uniswapRouter != address(0), "Invalid router");
        require(strataxParams.collateralToken != address(0), "Invalid collateral token");
        require(strataxParams.borrowToken != address(0), "Invalid borrow token");
        require(strataxParams.strataxOracle != address(0), "Invalid oracle");
        require(strataxParams.feeCollector != address(0), "Invalid fee collector");

        aavePool = IPool(lendingParams.aavePool);
        aaveDataProvider = IProtocolDataProvider(lendingParams.aaveDataProvider);
        uniswapRouter = IUniswapV3SwapRouter(swapParams.uniswapRouter);
        strataxPositionNft = IStrataxPositionNft(strataxParams.strataxPositionNft);

        tokenId = strataxParams.tokenId;
        collateralToken = strataxParams.collateralToken;
        borrowToken = strataxParams.borrowToken;
        strataxOracle = strataxParams.strataxOracle;
        feeCollector = strataxParams.feeCollector;

        flashLoanFeeBps = aavePool.FLASHLOAN_PREMIUM_TOTAL();
        maxLeverageOffset = lendingParams.maxLeverageOffset;

        collateralTokenDecimals = IERC20Metadata(strataxParams.collateralToken).decimals();
        borrowTokenDecimals = IERC20Metadata(strataxParams.borrowToken).decimals();

        if (lendingParams.borrowSafetyMargin == 0) {
            borrowSafetyMargin = 9900;
        } else {
            require(
                lendingParams.borrowSafetyMargin < StrataxCalculations.BORROW_SAFETY_PRECISION, "Invalid safety margin"
            );
            borrowSafetyMargin = lendingParams.borrowSafetyMargin;
        }
    }

    /**
     * @notice Creates/increases a leveraged position using desired leverage directly.
     * @dev No external calculateOpenParams call is required.
     */
    function createLeveragedPosition(
        uint256 desiredLeverage,
        uint256 collateralAmount,
        uint24 poolFee,
        uint256 minReturnAmount
    ) public onlyOwner {
        StrataxAaveUniswapCombinedLib.CreateLeveragedPositionParams memory params =
            StrataxAaveUniswapCombinedLib.CreateLeveragedPositionParams({
                desiredLeverage: desiredLeverage,
                collateralAmount: collateralAmount,
                poolFee: poolFee,
                minReturnAmount: minReturnAmount
            });

        _createLeveragedPosition(params);
    }

    function _createLeveragedPosition(StrataxAaveUniswapCombinedLib.CreateLeveragedPositionParams memory createParams)
        internal
    {
        require(!isBurned, "Position is burned, only unwinding allowed");
        require(createParams.desiredLeverage >= StrataxCalculations.LEVERAGE_PRECISION, "Leverage must be >= 1x");

        // Supply idle collateral first if any.
        uint256 idleCollateral = IERC20(collateralToken).balanceOf(address(this));
        if (idleCollateral > 0) {
            IERC20(collateralToken).forceApprove(address(aavePool), idleCollateral);
            aavePool.supply(collateralToken, idleCollateral, address(this), 0);
        }

        if (createParams.collateralAmount > 0) {
            IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), createParams.collateralAmount);
        }

        (uint256 flashLoanAmount, uint256 borrowAmount, uint256 strataxFeeAmount) =
            _computeOpenParams(createParams.desiredLeverage, createParams.collateralAmount);

        OpenParams memory params = OpenParams({
            collateralToken: collateralToken,
            collateralAmount: createParams.collateralAmount,
            borrowToken: borrowToken,
            borrowAmount: borrowAmount,
            strataxFeeAmount: strataxFeeAmount,
            poolFee: createParams.poolFee,
            minReturnAmount: createParams.minReturnAmount
        });

        bytes memory encodedParams = abi.encode(OperationType.OPEN, msg.sender, params);
        aavePool.flashLoanSimple(address(this), collateralToken, flashLoanAmount, encodedParams, 0);
    }

    function adjustPositionLeverage(uint256 desiredLeverage, uint24 poolFee, uint256 minReturnAmount)
        external
        onlyOwner
    {
        require(!isBurned, "Position is burned, only unwinding allowed");
        require(desiredLeverage >= StrataxCalculations.LEVERAGE_PRECISION, "Leverage must be >= 1x");

        uint256 currentLeverage = getCurrentLeverage();
        require(currentLeverage != desiredLeverage, "Already at target leverage");

        if (currentLeverage < desiredLeverage) {
            createLeveragedPosition(desiredLeverage, 0, poolFee, minReturnAmount);
            return;
        }

        uint256 positionUsdValue = getPositionUsdValue();
        require(positionUsdValue > 0, "No active equity");

        uint256 leverageDelta = currentLeverage - desiredLeverage;
        uint256 debtRepayUsdValue = (positionUsdValue * leverageDelta) / StrataxCalculations.LEVERAGE_PRECISION;

        uint256 feeBps = flashLoanFeeBps + IFeeCollector(feeCollector).strataxFee();
        uint256 denominator = StrataxCalculations.FLASHLOAN_FEE_PREC * StrataxCalculations.LEVERAGE_PRECISION;

        if (desiredLeverage > StrataxCalculations.LEVERAGE_PRECISION && feeBps > 0) {
            uint256 feeAdjustment = feeBps * (desiredLeverage - StrataxCalculations.LEVERAGE_PRECISION);
            require(feeAdjustment < denominator, "Target leverage too high");
            denominator = denominator - feeAdjustment;
        }

        debtRepayUsdValue =
            (debtRepayUsdValue
                    * StrataxCalculations.FLASHLOAN_FEE_PREC
                    * StrataxCalculations.LEVERAGE_PRECISION
                    + denominator
                    - 1) / denominator;

        uint256 borrowTokenPriceUsd = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        require(borrowTokenPriceUsd > 0, "Invalid borrow token price");

        uint256 debtToRepay =
            (debtRepayUsdValue * (10 ** borrowTokenDecimals) + borrowTokenPriceUsd - 1) / borrowTokenPriceUsd;
        require(debtToRepay > 0, "Debt repay too small");

        (uint256 collateralToWithdraw, uint256 debtAmount,) = calculateUnwindParams(debtToRepay);
        unwindPosition(collateralToWithdraw, debtAmount, poolFee, minReturnAmount);
    }

    function calculateUnwindParams(uint256 debtToRepay)
        public
        view
        returns (uint256 collateralToWithdraw, uint256 debtAmount, uint256 strataxFee)
    {
        return calculateUnwindParams(debtToRepay, DEFAULT_SLIPPAGE_BPS);
    }

    function calculateUnwindParams(uint256 debtToRepay, uint256 slippageBufferBps)
        public
        view
        returns (uint256 collateralToWithdraw, uint256 debtAmount, uint256 strataxFee)
    {
        (,, address variableDebtToken) = aaveDataProvider.getReserveTokensAddresses(borrowToken);
        debtAmount = IERC20(variableDebtToken).balanceOf(address(this));
        if (debtAmount <= debtToRepay) {
            debtToRepay = debtAmount;
        }

        uint256 debtTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);

        strataxFee = (debtToRepay * IFeeCollector(feeCollector).strataxFee()) / StrataxCalculations.FLASHLOAN_FEE_PREC;
        uint256 flashLoanFeeAmount = (debtToRepay * flashLoanFeeBps) / StrataxCalculations.FLASHLOAN_FEE_PREC;

        collateralToWithdraw =
            (debtTokenPrice * (debtToRepay + flashLoanFeeAmount + strataxFee) * (10 ** collateralTokenDecimals))
                / (collateralTokenPrice * (10 ** borrowTokenDecimals));

        collateralToWithdraw =
            (collateralToWithdraw * (StrataxCalculations.BPS + slippageBufferBps)) / StrataxCalculations.BPS;

        return (collateralToWithdraw, debtToRepay, strataxFee);
    }

    function unwindPosition(uint256 collateralToWithdraw, uint256 debtAmount, uint24 poolFee, uint256 minReturnAmount)
        public
        onlyOwner
    {
        UnwindParams memory params = UnwindParams({
            collateralToken: collateralToken,
            collateralToWithdraw: collateralToWithdraw,
            debtToken: borrowToken,
            debtAmount: debtAmount,
            poolFee: poolFee,
            minReturnAmount: minReturnAmount
        });

        bytes memory encodedParams = abi.encode(OperationType.UNWIND, msg.sender, params);
        aavePool.flashLoanSimple(address(this), borrowToken, debtAmount, encodedParams, 0);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        nonReentrant
        returns (bool)
    {
        require(msg.sender == address(aavePool), "Caller must be Aave Pool");
        require(initiator == address(this), "Initiator must be this contract");

        OperationType opType = abi.decode(params, (OperationType));
        if (opType == OperationType.OPEN) {
            return _executeOpenOperation(asset, amount, premium, params);
        }
        return _executeUnwindOperation(asset, amount, premium, params);
    }

    function _executeOpenOperation(address asset, uint256 amount, uint256 premium, bytes calldata params)
        internal
        returns (bool)
    {
        (, address user, OpenParams memory openParams) = abi.decode(params, (OperationType, address, OpenParams));

        uint256 borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        require(borrowTokenPrice > 0, "Borrow token price must be > 0");

        if (openParams.strataxFeeAmount > 0) {
            IERC20(asset).forceApprove(feeCollector, openParams.strataxFeeAmount);
            uint256 borrowAmountInUsd = (openParams.borrowAmount * borrowTokenPrice) / (10 ** borrowTokenDecimals);
            IFeeCollector(feeCollector)
                .collectFeesAndRecordVolume(asset, openParams.strataxFeeAmount, borrowToken, borrowAmountInUsd);
        }

        uint256 totalCollateralAfterFee = amount + openParams.collateralAmount - openParams.strataxFeeAmount;
        IERC20(asset).forceApprove(address(aavePool), totalCollateralAfterFee);
        aavePool.supply(asset, totalCollateralAfterFee, address(this), 0);

        aavePool.borrow(openParams.borrowToken, openParams.borrowAmount, VARIABLE_DEBT, 0, address(this));

        IERC20(openParams.borrowToken).forceApprove(address(uniswapRouter), openParams.borrowAmount);
        uint256 returnAmount = _swapExactInputSingle(
            openParams.borrowToken,
            openParams.collateralToken,
            openParams.poolFee,
            openParams.borrowAmount,
            openParams.minReturnAmount
        );

        uint256 totalDebt = amount + premium;
        require(returnAmount >= totalDebt, "Insufficient funds to repay flash loan");

        if (returnAmount > totalDebt) {
            uint256 leftover = returnAmount - totalDebt;
            IERC20(asset).forceApprove(address(aavePool), leftover);
            aavePool.supply(asset, leftover, address(this), 0);
        }

        IERC20(asset).forceApprove(address(aavePool), totalDebt);

        emit LeveragePositionCreated(
            user, asset, openParams.borrowToken, totalCollateralAfterFee, openParams.borrowAmount
        );
        return true;
    }

    function _executeUnwindOperation(address asset, uint256 amount, uint256 premium, bytes calldata params)
        internal
        returns (bool)
    {
        (, address user, UnwindParams memory unwindParams) = abi.decode(params, (OperationType, address, UnwindParams));

        IERC20(asset).forceApprove(address(aavePool), amount);
        aavePool.repay(asset, amount, VARIABLE_DEBT, address(this));

        uint256 debtTokenPrice = IStrataxOracle(strataxOracle).getPrice(asset);
        require(debtTokenPrice > 0, "Invalid prices");

        uint256 strataxFeeInDebtToken =
            (amount * IFeeCollector(feeCollector).strataxFee()) / StrataxCalculations.FLASHLOAN_FEE_PREC;

        uint256 withdrawnAmount =
            aavePool.withdraw(unwindParams.collateralToken, unwindParams.collateralToWithdraw, address(this));

        IERC20(unwindParams.collateralToken).forceApprove(address(uniswapRouter), withdrawnAmount);
        uint256 returnAmount = _swapExactInputSingle(
            unwindParams.collateralToken,
            borrowToken,
            unwindParams.poolFee,
            withdrawnAmount,
            unwindParams.minReturnAmount
        );

        uint256 totalDebt = amount + premium;
        require(returnAmount >= totalDebt, "Insufficient funds to repay flash loan");

        uint256 leftoverAfterRepay = returnAmount - totalDebt;
        if (strataxFeeInDebtToken > 0) {
            require(leftoverAfterRepay >= strataxFeeInDebtToken, "Insufficient funds for stratax fee");
            IERC20(asset).forceApprove(feeCollector, strataxFeeInDebtToken);

            uint256 borrowAmountInUsd = (amount * debtTokenPrice) / (10 ** borrowTokenDecimals);
            IFeeCollector(feeCollector)
                .collectFeesAndRecordVolume(asset, strataxFeeInDebtToken, asset, borrowAmountInUsd);

            leftoverAfterRepay = leftoverAfterRepay - strataxFeeInDebtToken;
        }

        if (leftoverAfterRepay > 0) {
            IERC20(asset).forceApprove(address(aavePool), leftoverAfterRepay);
            aavePool.supply(asset, leftoverAfterRepay, address(this), 0);
        }

        IERC20(asset).forceApprove(address(aavePool), totalDebt);

        emit PositionUnwound(user, unwindParams.collateralToken, asset, amount, withdrawnAmount);
        return true;
    }

    function _swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 poolFee,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        require(amountIn > 0, "Invalid amount in");
        require(tokenIn != address(0) && tokenOut != address(0), "Invalid token");

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        IUniswapV3SwapRouter.ExactInputSingleParams memory swapParams = IUniswapV3SwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = uniswapRouter.exactInputSingle(swapParams);
        require(amountOut >= minAmountOut, "Insufficient return amount from swap");

        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        require(balanceAfter > balanceBefore, "Destination token not received");
    }

    function _computeOpenParams(uint256 desiredLeverage, uint256 collateralAmount)
        internal
        view
        returns (uint256 flashLoanAmount, uint256 borrowAmount, uint256 strataxFee)
    {
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(collateralToken);
        require(ltv > 0, "Asset not usable as collateral");

        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        uint256 borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);

        require(collateralTokenPrice > 0, "Collateral token price must be > 0");
        require(borrowTokenPrice > 0, "Borrow token price must be > 0");

        uint256 freeCollateral = _getFreeCollateral(collateralTokenPrice, borrowTokenPrice, ltv);
        uint256 totalCollateralAmount = collateralAmount + freeCollateral;
        require(totalCollateralAmount > 0, "Collateral must be > 0");

        StrataxCalculations.CalcParams memory calcParams = StrataxCalculations.CalcParams({
            desiredLeverage: desiredLeverage,
            collateralAmount: totalCollateralAmount,
            collateralTokenPrice: collateralTokenPrice,
            borrowTokenPrice: borrowTokenPrice,
            collateralTokenDecimals: collateralTokenDecimals,
            borrowTokenDecimals: borrowTokenDecimals,
            ltv: ltv,
            borrowSafetyMargin: borrowSafetyMargin,
            flashLoanFeeBps: flashLoanFeeBps,
            strataxFeeBps: IFeeCollector(feeCollector).strataxFee(),
            maxLeverageOffset: maxLeverageOffset
        });

        StrataxCalculations.CalcResult memory result = StrataxCalculations.calculateOpenParams(calcParams);
        return (result.flashLoanAmount, result.borrowAmount, result.strataxFee);
    }

    function _getFreeCollateral(uint256 collateralTokenPrice, uint256 borrowTokenPrice, uint256 ltv)
        internal
        view
        returns (uint256 freeCollateral)
    {
        (address aTokenCollateral,,) = aaveDataProvider.getReserveTokensAddresses(collateralToken);
        uint256 aTokenBalance = IERC20(aTokenCollateral).balanceOf(address(this));

        (,, address variableDebtToken) = aaveDataProvider.getReserveTokensAddresses(borrowToken);
        uint256 debtTokenAmount = IERC20(variableDebtToken).balanceOf(address(this));

        uint256 collateralBackingDebt = (debtTokenAmount * borrowTokenPrice * (10 ** collateralTokenDecimals))
            / (collateralTokenPrice * (10 ** borrowTokenDecimals));
        require(ltv > 0, "Invalid LTV");

        collateralBackingDebt = (collateralBackingDebt * StrataxCalculations.LTV_PRECISION + ltv - 1) / ltv;

        if (aTokenBalance >= collateralBackingDebt) {
            freeCollateral = aTokenBalance - collateralBackingDebt;
        }
    }

    function owner() public view returns (address) {
        return strataxPositionNft.ownerOf(tokenId);
    }

    function getCurrentLeverage() public view returns (uint256 currentLeverage) {
        (address aTokenCollateral,,) = aaveDataProvider.getReserveTokensAddresses(collateralToken);
        (,, address variableDebtToken) = aaveDataProvider.getReserveTokensAddresses(borrowToken);

        uint256 aTokenBalance = IERC20(aTokenCollateral).balanceOf(address(this));
        uint256 debtTokenAmount = IERC20(variableDebtToken).balanceOf(address(this));

        if (aTokenBalance == 0) {
            return 0;
        }
        if (debtTokenAmount == 0) {
            return StrataxCalculations.LEVERAGE_PRECISION;
        }

        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        uint256 borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        require(collateralTokenPrice > 0, "Collateral token price must be > 0");
        require(borrowTokenPrice > 0, "Borrow token price must be > 0");

        uint256 totalCollateralValueUsd = (aTokenBalance * collateralTokenPrice) / (10 ** collateralTokenDecimals);
        uint256 totalDebtValueUsd = (debtTokenAmount * borrowTokenPrice) / (10 ** borrowTokenDecimals);

        uint256 equity = totalCollateralValueUsd - totalDebtValueUsd;
        require(equity > 0, "Invalid position: debt exceeds collateral");

        currentLeverage = (totalCollateralValueUsd * StrataxCalculations.LEVERAGE_PRECISION) / equity;
    }

    function getPositionUsdValue() public view returns (uint256 positionValueUsd) {
        (address aTokenCollateral,,) = aaveDataProvider.getReserveTokensAddresses(collateralToken);
        (,, address variableDebtToken) = aaveDataProvider.getReserveTokensAddresses(borrowToken);

        uint256 aTokenBalance = IERC20(aTokenCollateral).balanceOf(address(this));
        uint256 debtTokenAmount = IERC20(variableDebtToken).balanceOf(address(this));

        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        uint256 borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        require(collateralTokenPrice > 0, "Collateral token price must be > 0");
        require(borrowTokenPrice > 0, "Borrow token price must be > 0");

        uint256 totalCollateralValueUsd = (aTokenBalance * collateralTokenPrice) / (10 ** collateralTokenDecimals);
        uint256 totalDebtValueUsd = (debtTokenAmount * borrowTokenPrice) / (10 ** borrowTokenDecimals);

        if (totalCollateralValueUsd >= totalDebtValueUsd) {
            positionValueUsd = totalCollateralValueUsd - totalDebtValueUsd;
        } else {
            positionValueUsd = 0;
        }
    }

    function burnPosition(address newOwner) external onlyOwner {
        strataxPositionNft.burn(tokenId);
        burnedTokenOwner = newOwner;
        isBurned = true;
        emit PositionBurned(msg.sender, tokenId);
    }

    function recoverTokens(address token, uint256 amount) external onlyOwner {
        require(isBurned, "Position must be burned to recover tokens");
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function supplyCollateral(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than zero");

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(collateralToken).forceApprove(address(aavePool), amount);
        aavePool.supply(collateralToken, amount, address(this), 0);

        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        emit CollateralSupplied(msg.sender, collateralToken, amount, healthFactor);
    }

    function withdrawCollateral(uint256 amount) external onlyOwner returns (uint256 amountWithdrawn) {
        require(amount > 0, "Amount must be greater than zero");

        amountWithdrawn = aavePool.withdraw(collateralToken, amount, msg.sender);
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        require(healthFactor > 1e18, "Withdrawal would make position unhealthy");

        emit CollateralWithdrawn(msg.sender, collateralToken, amountWithdrawn, healthFactor);
        return amountWithdrawn;
    }

    function borrowDebtToken(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than zero");

        aavePool.borrow(borrowToken, amount, VARIABLE_DEBT, 0, address(this));
        IERC20(borrowToken).safeTransfer(msg.sender, amount);

        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        require(healthFactor > 1e18, "Borrow would make position unhealthy");
    }

    function repayDebtToken(uint256 amount) external onlyOwner returns (uint256 amountRepaid) {
        require(amount > 0, "Amount must be greater than zero");

        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(borrowToken).forceApprove(address(aavePool), amount);

        amountRepaid = aavePool.repay(borrowToken, amount, VARIABLE_DEBT, address(this));
    }

    function updateFlashLoanFee() external onlyOwner {
        uint256 oldFee = flashLoanFeeBps;
        flashLoanFeeBps = aavePool.FLASHLOAN_PREMIUM_TOTAL();
        require(flashLoanFeeBps < StrataxCalculations.FLASHLOAN_FEE_PREC, "Fee must be < 100%");
        emit FlashLoanFeeUpdated(flashLoanFeeBps, oldFee);
    }

    function updateUniswapRouter(address newRouter) external onlyOwner {
        require(newRouter != address(0), "Invalid router address");
        address oldRouter = address(uniswapRouter);
        uniswapRouter = IUniswapV3SwapRouter(newRouter);
        emit UniswapRouterUpdated(newRouter, oldRouter);
    }

    function updateBorrowSafetyMargin(uint256 newMargin) external onlyOwner {
        require(newMargin > 0 && newMargin < StrataxCalculations.BORROW_SAFETY_PRECISION, "Invalid safety margin");
        uint256 oldMargin = borrowSafetyMargin;
        borrowSafetyMargin = newMargin;
        emit BorrowSafetyMarginUpdated(newMargin, oldMargin);
    }

    function updateMaxLeverageOffset(uint256 newOffset) external onlyOwner {
        require(newOffset <= 500, "Max leverage offset too high");
        uint256 oldOffset = maxLeverageOffset;
        maxLeverageOffset = newOffset;
        emit MaxLeverageOffsetUpdated(newOffset, oldOffset);
    }
}
