// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IUniswapV3SwapRouter} from "../../interfaces/external/IUniswapV3SwapRouter.sol";
import {IFluidVaultT1} from "../../interfaces/external/IFluidVaultT1.sol";
import {IFluidLiquidity} from "../../interfaces/external/IFluidLiquidity.sol";
import {IStrataxOracle} from "../../interfaces/internal/IStrataxOracle.sol";
import {IFeeCollector} from "../../interfaces/internal/IFeeCollector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StrataxCalculations} from "../../libraries/StrataxCalculations.sol";
import {StrataxFluidLib} from "../../libraries/lending/StrataxFluidLib.sol";
import {StrataxUniswapLib} from "../../libraries/swapping/StrataxUniswapLib.sol";
import {StrataxCoreLib} from "../../libraries/stratax/StrataxCoreLib.sol";
import {BaseStrataxPosition} from "./BaseStrataxPosition.sol";

contract Stratax_Fluid_Uniswap is BaseStrataxPosition {
    using SafeERC20 for IERC20;

    uint256 internal constant MAX_LEVERAGE_STEPS = 8;
    uint256 internal constant MAX_BORROW_ATTEMPTS_PER_STEP = 6;
    address internal constant FLUID_NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint256 public fluidNftId;

    IFluidVaultT1 public fluidVault;
    IFluidLiquidity public fluidLiquidity;
    IUniswapV3SwapRouter public uniswapRouter;

    // Deprecated local accounting slots retained for storage compatibility.
    uint256 public trackedCollateral;
    uint256 public trackedDebt;

    uint256 public fluidCollateralCached;
    uint256 public fluidDebtCached;

    uint256[48] private __gap;

    event CollateralSupplied(address indexed user, address collateralToken, uint256 amount);
    event CollateralWithdrawn(address indexed user, address collateralToken, uint256 amount);
    event UniswapRouterUpdated(address newRouter, address oldRouter);
    event FluidVaultUpdated(address newVault, address oldVault);

    function initialize(
        StrataxFluidLib.PositionInitParams calldata lendingParams,
        StrataxUniswapLib.InitParams calldata swapParams,
        StrataxCoreLib.InitParams calldata strataxParams
    ) external initializer {
        require(lendingParams.fluidVault != address(0), "Invalid fluid vault");
        require(swapParams.uniswapRouter != address(0), "Invalid router");
        require(strataxParams.collateralToken != address(0), "Invalid collateral token");
        require(strataxParams.borrowToken != address(0), "Invalid borrow token");
        require(strataxParams.strataxOracle != address(0), "Invalid oracle");
        require(strataxParams.feeCollector != address(0), "Invalid fee collector");

        _initBase(strataxParams, lendingParams.borrowSafetyMargin, lendingParams.maxLeverageOffset);

        fluidVault = IFluidVaultT1(lendingParams.fluidVault);
        fluidLiquidity = IFluidLiquidity(fluidVault.LIQUIDITY());
        uniswapRouter = IUniswapV3SwapRouter(swapParams.uniswapRouter);
    }

    function createLeveragedPosition(
        uint256 desiredLeverage,
        uint256 collateralAmount,
        uint24 poolFee,
        uint256 minReturnAmount
    ) public onlyOwner nonReentrant {
        require(!isBurned, "Position is burned, only unwinding allowed");
        require(desiredLeverage >= StrataxCalculations.LEVERAGE_PRECISION, "Leverage must be >= 1x");

        if (collateralAmount > 0) {
            IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
            _supplyCollateralToFluid(collateralAmount);
        }

        uint256 totalBorrowed;
        uint256 totalSwapped;

        for (uint256 step; step < MAX_LEVERAGE_STEPS; ++step) {
            uint256 borrowAmount = _computeAdditionalDebtAmount(desiredLeverage);
            if (borrowAmount == 0) {
                break;
            }

            // Prefer liquidity callback borrowing for efficiency, but keep a vault fallback.
            uint256 borrowedThisStep = _liquidityBorrowWithBackoff(borrowAmount);
            if (borrowedThisStep == 0) {
                borrowedThisStep = _borrowWithBackoff(borrowAmount);
            }
            if (borrowedThisStep == 0) {
                break;
            }

            uint256 swappedCollateral = _collectFeeSwapAndResupply(borrowedThisStep, poolFee, minReturnAmount);
            totalBorrowed += borrowedThisStep;
            totalSwapped += swappedCollateral;
        }

        emit LeveragePositionCreated(
            msg.sender, collateralToken, borrowToken, collateralAmount + totalSwapped, totalBorrowed
        );
    }

    function createLeveragedPositionFlashloanOnly(
        uint256 desiredLeverage,
        uint256 collateralAmount,
        uint24 poolFee,
        uint256 minReturnAmount
    ) public onlyOwner nonReentrant returns (uint256 totalBorrowed, uint256 totalSwapped, uint256 totalFeesPaid) {
        require(!isBurned, "Position is burned, only unwinding allowed");
        require(desiredLeverage >= StrataxCalculations.LEVERAGE_PRECISION, "Leverage must be >= 1x");
        require(address(fluidLiquidity) != address(0), "Invalid Fluid liquidity");

        if (collateralAmount > 0) {
            IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
            _supplyCollateralToFluid(collateralAmount);
        }

        uint256 strataxFeeBps = IFeeCollector(feeCollector).strataxFee();

        for (uint256 step; step < MAX_LEVERAGE_STEPS; ++step) {
            uint256 borrowAmount = _computeAdditionalDebtAmount(desiredLeverage);
            if (borrowAmount == 0) {
                break;
            }

            uint256 borrowedThisStep = _liquidityBorrowWithBackoff(borrowAmount);
            if (borrowedThisStep == 0) {
                break;
            }

            totalFeesPaid += (borrowedThisStep * strataxFeeBps) / StrataxCalculations.FLASHLOAN_FEE_PREC;
            uint256 swappedCollateral = _collectFeeSwapAndResupply(borrowedThisStep, poolFee, minReturnAmount);
            totalBorrowed += borrowedThisStep;
            totalSwapped += swappedCollateral;
        }

        emit LeveragePositionCreated(
            msg.sender, collateralToken, borrowToken, collateralAmount + totalSwapped, totalBorrowed
        );
    }

    function liquidityCallback(address token_, uint256 amount_, bytes calldata) external {
        require(msg.sender == address(fluidLiquidity), "Only Fluid liquidity");
        if (amount_ == 0) {
            return;
        }

        if (token_ == FLUID_NATIVE_TOKEN) {
            (bool sent,) = payable(msg.sender).call{value: amount_}("");
            require(sent, "Native callback transfer failed");
            return;
        }

        IERC20(token_).safeTransfer(msg.sender, amount_);
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
        (uint256 totalCollateral, uint256 totalDebt) = _getCachedPosition();
        debtAmount = totalDebt;
        if (debtAmount <= debtToRepay) {
            debtToRepay = debtAmount;
        }

        uint256 debtTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);

        strataxFee = (debtToRepay * IFeeCollector(feeCollector).strataxFee()) / StrataxCalculations.FLASHLOAN_FEE_PREC;

        collateralToWithdraw = (debtTokenPrice * (debtToRepay + strataxFee) * (10 ** collateralTokenDecimals))
            / (collateralTokenPrice * (10 ** borrowTokenDecimals));

        collateralToWithdraw =
            (collateralToWithdraw * (StrataxCalculations.BPS + slippageBufferBps)) / StrataxCalculations.BPS;

        if (collateralToWithdraw > totalCollateral) {
            collateralToWithdraw = totalCollateral;
        }

        return (collateralToWithdraw, debtToRepay, strataxFee);
    }

    function unwindPosition(uint256 collateralToWithdraw, uint256 debtAmount, uint24 poolFee, uint256 minReturnAmount)
        public
        onlyOwner
        nonReentrant
    {
        require(collateralToWithdraw > 0, "Invalid collateral amount");

        _withdrawCollateralFromFluid(collateralToWithdraw);

        IERC20(collateralToken).forceApprove(address(uniswapRouter), collateralToWithdraw);
        uint256 returnAmount =
            _swapExactInputSingle(collateralToken, borrowToken, poolFee, collateralToWithdraw, minReturnAmount);

        (, uint256 totalDebt) = _getCachedPosition();
        uint256 repayAmount = debtAmount;
        if (repayAmount > totalDebt) {
            repayAmount = totalDebt;
        }
        if (repayAmount > returnAmount) {
            repayAmount = returnAmount;
        }

        if (repayAmount > 0) {
            _repayDebtToFluid(repayAmount);
        }

        uint256 leftover = IERC20(borrowToken).balanceOf(address(this));
        if (leftover > 0) {
            IERC20(borrowToken).safeTransfer(msg.sender, leftover);
        }

        emit PositionUnwound(msg.sender, collateralToken, borrowToken, repayAmount, collateralToWithdraw);
    }

    function _getTotalCollateralAndDebt()
        internal
        view
        override
        returns (uint256 totalCollateral, uint256 totalDebt)
    {
        return _getCachedPosition();
    }

    function supplyCollateral(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be greater than zero");

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        _supplyCollateralToFluid(amount);

        emit CollateralSupplied(msg.sender, collateralToken, amount);
    }

    function withdrawCollateral(uint256 amount) external onlyOwner nonReentrant returns (uint256 amountWithdrawn) {
        require(amount > 0, "Amount must be greater than zero");

        _withdrawCollateralFromFluid(amount);
        IERC20(collateralToken).safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, collateralToken, amount);
        return amount;
    }

    function borrowDebtToken(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be greater than zero");

        _borrowDebtFromFluid(amount);
        IERC20(borrowToken).safeTransfer(msg.sender, amount);
    }

    function repayDebtToken(uint256 amount) external onlyOwner nonReentrant returns (uint256 amountRepaid) {
        require(amount > 0, "Amount must be greater than zero");

        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), amount);
        (, uint256 totalDebt) = _getCachedPosition();
        if (amount > totalDebt) {
            amount = totalDebt;
        }

        _repayDebtToFluid(amount);
        return amount;
    }

    function updateUniswapRouter(address newRouter) external onlyOwner {
        require(newRouter != address(0), "Invalid router address");
        address oldRouter = address(uniswapRouter);
        uniswapRouter = IUniswapV3SwapRouter(newRouter);
        emit UniswapRouterUpdated(newRouter, oldRouter);
    }

    function updateFluidVault(address newVault) external onlyOwner {
        require(newVault != address(0), "Invalid vault address");
        address oldVault = address(fluidVault);
        fluidVault = IFluidVaultT1(newVault);
        fluidLiquidity = IFluidLiquidity(fluidVault.LIQUIDITY());
        emit FluidVaultUpdated(newVault, oldVault);
    }

    function _computeAdditionalDebtAmount(uint256 desiredLeverage)
        internal
        view
        returns (uint256 additionalDebtAmount)
    {
        uint256 equityUsd = getPositionUsdValue();
        if (equityUsd == 0) {
            return 0;
        }

        uint256 desiredDebtUsd = (equityUsd * (desiredLeverage - StrataxCalculations.LEVERAGE_PRECISION))
            / StrataxCalculations.LEVERAGE_PRECISION;

        uint256 maxDebtUsd = (desiredDebtUsd * borrowSafetyMargin) / StrataxCalculations.BORROW_SAFETY_PRECISION;

        uint256 debtTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        require(debtTokenPrice > 0, "Borrow token price must be > 0");

        (, uint256 totalDebt) = _getCachedPosition();
        uint256 currentDebtUsd = (totalDebt * debtTokenPrice) / (10 ** borrowTokenDecimals);
        if (currentDebtUsd >= maxDebtUsd) {
            return 0;
        }

        uint256 deltaDebtUsd = maxDebtUsd - currentDebtUsd;
        additionalDebtAmount = (deltaDebtUsd * (10 ** borrowTokenDecimals)) / debtTokenPrice;
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

    function _supplyCollateralToFluid(uint256 amount) internal {
        require(amount <= uint256(type(int256).max), "Amount too large");
        IERC20(collateralToken).forceApprove(address(fluidVault), amount);
        (uint256 returnedNftId, int256 collateralInt, int256 debtInt) =
            fluidVault.operate(fluidNftId, int256(amount), 0, address(this));
        _syncFluidNftId(returnedNftId);
        _syncCachedPosition(collateralInt, debtInt);
    }

    function _withdrawCollateralFromFluid(uint256 amount) internal {
        require(amount <= uint256(type(int256).max), "Amount too large");
        require(fluidNftId != 0, "Fluid position not initialized");

        (uint256 totalCollateral,) = _getCachedPosition();
        require(amount <= totalCollateral, "Insufficient collateral");

        (uint256 returnedNftId, int256 collateralInt, int256 debtInt) =
            fluidVault.operate(fluidNftId, -int256(amount), 0, address(this));
        _syncFluidNftId(returnedNftId);
        _syncCachedPosition(collateralInt, debtInt);
    }

    function _borrowDebtFromFluid(uint256 amount) internal {
        require(amount <= uint256(type(int256).max), "Amount too large");
        require(fluidNftId != 0, "Fluid position not initialized");
        (uint256 returnedNftId, int256 collateralInt, int256 debtInt) =
            fluidVault.operate(fluidNftId, 0, int256(amount), address(this));
        _syncFluidNftId(returnedNftId);
        _syncCachedPosition(collateralInt, debtInt);
    }

    function _borrowWithBackoff(uint256 targetAmount) internal returns (uint256 borrowedAmount) {
        uint256 attemptAmount = targetAmount;
        for (uint256 attempt; attempt < MAX_BORROW_ATTEMPTS_PER_STEP; ++attempt) {
            if (_tryBorrowDebtFromFluid(attemptAmount)) {
                return attemptAmount;
            }

            if (attemptAmount <= 1) {
                break;
            }
            attemptAmount = (attemptAmount * 8) / 10;
        }

        return 0;
    }

    function _liquidityBorrowWithBackoff(uint256 targetAmount) internal returns (uint256 borrowedAmount) {
        uint256 attemptAmount = targetAmount;
        for (uint256 attempt; attempt < MAX_BORROW_ATTEMPTS_PER_STEP; ++attempt) {
            if (_tryLiquidityBorrow(attemptAmount)) {
                return attemptAmount;
            }

            if (attemptAmount <= 1) {
                break;
            }
            attemptAmount = (attemptAmount * 8) / 10;
        }

        return 0;
    }

    function _tryBorrowDebtFromFluid(uint256 amount) internal returns (bool) {
        if (amount == 0 || amount > uint256(type(int256).max) || fluidNftId == 0) {
            return false;
        }

        try fluidVault.operate(fluidNftId, 0, int256(amount), address(this)) returns (
            uint256 returnedNftId, int256 collateralInt, int256 debtInt
        ) {
            _syncFluidNftId(returnedNftId);
            _syncCachedPosition(collateralInt, debtInt);
            return true;
        } catch {
            return false;
        }
    }

    function _collectFeeSwapAndResupply(uint256 borrowedAmount, uint24 poolFee, uint256 minReturnAmount)
        internal
        returns (uint256 swappedCollateral)
    {
        uint256 strataxFeeInDebtToken = (borrowedAmount * IFeeCollector(feeCollector).strataxFee())
            / StrataxCalculations.FLASHLOAN_FEE_PREC;

        uint256 swapAmount = borrowedAmount;
        if (strataxFeeInDebtToken > 0) {
            IERC20(borrowToken).forceApprove(feeCollector, strataxFeeInDebtToken);
            uint256 borrowAmountInUsd =
                (borrowedAmount * IStrataxOracle(strataxOracle).getPrice(borrowToken)) / (10 ** borrowTokenDecimals);
            IFeeCollector(feeCollector)
                .collectFeesAndRecordVolume(borrowToken, strataxFeeInDebtToken, borrowToken, borrowAmountInUsd);
            swapAmount = borrowedAmount - strataxFeeInDebtToken;
        }

        IERC20(borrowToken).forceApprove(address(uniswapRouter), swapAmount);
        swappedCollateral = _swapExactInputSingle(borrowToken, collateralToken, poolFee, swapAmount, minReturnAmount);
        _supplyCollateralToFluid(swappedCollateral);
    }

    function _collectFeeSwapAndResupplyViaLiquidity(uint256 borrowedAmount, uint24 poolFee, uint256 minReturnAmount)
        internal
        returns (uint256 swappedCollateral)
    {
        uint256 strataxFeeInDebtToken =
            (borrowedAmount * IFeeCollector(feeCollector).strataxFee()) / StrataxCalculations.FLASHLOAN_FEE_PREC;

        uint256 swapAmount = borrowedAmount;
        if (strataxFeeInDebtToken > 0) {
            IERC20(borrowToken).forceApprove(feeCollector, strataxFeeInDebtToken);
            uint256 borrowAmountInUsd =
                (borrowedAmount * IStrataxOracle(strataxOracle).getPrice(borrowToken)) / (10 ** borrowTokenDecimals);
            IFeeCollector(feeCollector)
                .collectFeesAndRecordVolume(borrowToken, strataxFeeInDebtToken, borrowToken, borrowAmountInUsd);
            swapAmount = borrowedAmount - strataxFeeInDebtToken;
        }

        IERC20(borrowToken).forceApprove(address(uniswapRouter), swapAmount);
        swappedCollateral = _swapExactInputSingle(borrowToken, collateralToken, poolFee, swapAmount, minReturnAmount);
        _liquiditySupplyCollateral(swappedCollateral);
    }

    function _liquiditySupplyCollateral(uint256 amount) internal {
        require(amount <= uint256(type(int256).max), "Amount too large");
        fluidLiquidity.operate(collateralToken, int256(amount), 0, address(this), address(this), bytes(""));
        fluidCollateralCached += amount;
    }

    function _tryLiquidityBorrow(uint256 amount) internal returns (bool) {
        if (amount == 0 || amount > uint256(type(int256).max)) {
            return false;
        }

        try fluidLiquidity.operate(borrowToken, 0, int256(amount), address(this), address(this), bytes("")) returns (
            uint256, uint256
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _repayDebtToFluid(uint256 amount) internal {
        require(amount <= uint256(type(int256).max), "Amount too large");
        IERC20(borrowToken).forceApprove(address(fluidVault), amount);
        require(fluidNftId != 0, "Fluid position not initialized");

        (, uint256 totalDebt) = _getCachedPosition();
        require(amount <= totalDebt, "Repay exceeds debt");

        (uint256 returnedNftId, int256 collateralInt, int256 debtInt) =
            fluidVault.operate(fluidNftId, 0, -int256(amount), address(this));
        _syncFluidNftId(returnedNftId);
        _syncCachedPosition(collateralInt, debtInt);
    }

    function _getCachedPosition() internal view returns (uint256 collateralAmount, uint256 debtAmount) {
        collateralAmount = fluidCollateralCached;
        debtAmount = fluidDebtCached;
    }

    function _syncCachedPosition(int256 collateralInt, int256 debtInt) internal {
        fluidCollateralCached = collateralInt > 0 ? uint256(collateralInt) : 0;
        fluidDebtCached = debtInt > 0 ? uint256(debtInt) : 0;
    }

    function _syncFluidNftId(uint256 returnedNftId) internal {
        require(returnedNftId != 0, "Invalid Fluid NFT ID");
        if (fluidNftId == 0) {
            fluidNftId = returnedNftId;
            return;
        }
        require(returnedNftId == fluidNftId, "Fluid NFT mismatch");
    }
}
