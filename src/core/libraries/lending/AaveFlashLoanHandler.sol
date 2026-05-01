// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPool} from "../../../interfaces/external/IPool.sol";
import {ISwapExecutor} from "../../interfaces/internal/ISwapExecutor.sol";
import {IFeeCollector} from "../../../interfaces/internal/IFeeCollector.sol";
import {IStrataxOracle} from "../../../interfaces/internal/IStrataxOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StrataxCalculations} from "../../../libraries/StrataxCalculations.sol";

/**
 * @title AaveFlashLoanHandler
 * @notice Shared flash loan callback orchestration for Aave positions.
 * @dev Encapsulates open/unwind flows so DEX-specific swap executors can plug in.
 */
library AaveFlashLoanHandler {
    using SafeERC20 for IERC20;

    uint256 private constant VARIABLE_DEBT = 2;

    struct OpenFlashLoanParams {
        address collateralToken;
        uint256 collateralAmount;
        address borrowToken;
        uint256 borrowAmount;
        uint256 strataxFeeAmount;
        bytes swapData;
        uint256 minReturnAmount;
    }

    struct UnwindFlashLoanParams {
        address collateralToken;
        uint256 collateralToWithdraw;
        address debtToken;
        uint256 debtAmount;
        bytes swapData;
        uint256 minReturnAmount;
    }

    /**
     * @notice Execute the open position flash loan callback logic.
     * @dev Called from position contract's executeOperation() after Aave pool callback auth.
     * @param aavePool The Aave pool (for supply/borrow operations)
     * @param asset The flash loaned asset (collateral token)
     * @param amount Amount flash loaned
     * @param premium Aave flash loan premium
     * @param swapExecutor The DEX-specific swap executor
     * @param feeCollectorAddr The Stratax fee collector address
     * @param params Flash loan parameters
     * @return True if callback succeeds
     */
    function executeOpen(
        IPool aavePool,
        address swapRouter,
        address asset,
        uint256 amount,
        uint256 premium,
        ISwapExecutor swapExecutor,
        address feeCollectorAddr,
        address strataxOracleAddr,
        OpenFlashLoanParams memory params
    ) internal returns (bool) {
        // Step 1: Pay Stratax fee if present
        if (params.strataxFeeAmount > 0) {
            IERC20(asset).forceApprove(feeCollectorAddr, params.strataxFeeAmount);
            IFeeCollector feeCollector = IFeeCollector(feeCollectorAddr);
            uint256 borrowAmountInUsd = _toUsdAmount(params.borrowToken, params.borrowAmount, strataxOracleAddr);
            feeCollector.collectFeesAndRecordVolume(
                asset, params.strataxFeeAmount, params.borrowToken, borrowAmountInUsd
            );
        }

        // Step 2: Supply total collateral to Aave (flash loan + user supplied)
        uint256 totalCollateralAfterFee = amount + params.collateralAmount - params.strataxFeeAmount;
        IERC20(asset).forceApprove(address(aavePool), totalCollateralAfterFee);
        aavePool.supply(asset, totalCollateralAfterFee, address(this), 0);

        // Step 3: Borrow from Aave
        aavePool.borrow(params.borrowToken, params.borrowAmount, VARIABLE_DEBT, 0, address(this));

        // Step 4: Swap borrow token back to collateral via executor
        IERC20(params.borrowToken).forceApprove(address(swapExecutor), params.borrowAmount);
        uint256 returnAmount = swapExecutor.executeSwap(
            swapRouter, params.borrowToken, asset, params.borrowAmount, params.swapData, params.minReturnAmount
        );

        // Step 5: Repay flash loan
        uint256 totalDebt = amount + premium;
        require(returnAmount >= totalDebt, "Insufficient funds to repay flash loan");

        // Step 6: Supply leftover to Aave
        if (returnAmount > totalDebt) {
            uint256 leftover = returnAmount - totalDebt;
            IERC20(asset).forceApprove(address(aavePool), leftover);
            aavePool.supply(asset, leftover, address(this), 0);
        }

        // Step 7: Approve flash loan repayment
        IERC20(asset).forceApprove(address(aavePool), totalDebt);

        return true;
    }

    /**
     * @notice Execute the unwind position flash loan callback logic.
     * @dev Called from position contract's executeOperation() after Aave pool callback auth.
     */
    function executeUnwind(
        IPool aavePool,
        address swapRouter,
        address asset,
        uint256 amount,
        uint256 premium,
        ISwapExecutor swapExecutor,
        address feeCollectorAddr,
        UnwindFlashLoanParams memory params
    ) internal returns (bool) {
        // Step 1: Repay Aave debt with flash loaned tokens
        IERC20(asset).forceApprove(address(aavePool), amount);
        aavePool.repay(asset, amount, VARIABLE_DEBT, address(this));

        // Step 2: Withdraw collateral from Aave
        uint256 withdrawnAmount = aavePool.withdraw(params.collateralToken, params.collateralToWithdraw, address(this));

        // Step 3: Swap collateral back to debt token via executor
        IERC20(params.collateralToken).forceApprove(address(swapExecutor), withdrawnAmount);
        uint256 returnAmount = swapExecutor.executeSwap(
            swapRouter, params.collateralToken, asset, withdrawnAmount, params.swapData, params.minReturnAmount
        );

        // Step 4: Repay flash loan + premium
        uint256 totalDebt = amount + premium;
        require(returnAmount >= totalDebt, "Insufficient funds to repay flash loan");

        // Step 5: Collect Stratax fee
        uint256 strataxFeeInDebtToken =
            (amount * IFeeCollector(feeCollectorAddr).strataxFee()) / StrataxCalculations.FLASHLOAN_FEE_PREC;

        uint256 leftoverAfterRepay = returnAmount - totalDebt;
        if (strataxFeeInDebtToken > 0) {
            uint256 feeToCollect = strataxFeeInDebtToken;
            if (feeToCollect > leftoverAfterRepay) {
                feeToCollect = leftoverAfterRepay;
            }

            IERC20(asset).forceApprove(feeCollectorAddr, feeToCollect);
            uint256 amountInUsd = _toUsdAmount(asset, amount, address(0));
            IFeeCollector(feeCollectorAddr).collectFeesAndRecordVolume(asset, feeToCollect, asset, amountInUsd);
            leftoverAfterRepay = leftoverAfterRepay - feeToCollect;
        }

        // Step 6: Supply leftover to Aave
        if (leftoverAfterRepay > 0) {
            IERC20(asset).forceApprove(address(aavePool), leftoverAfterRepay);
            aavePool.supply(asset, leftoverAfterRepay, address(this), 0);
        }

        // Step 7: Approve flash loan repayment
        IERC20(asset).forceApprove(address(aavePool), totalDebt);

        return true;
    }

    function _toUsdAmount(address token, uint256 amount, address strataxOracleAddr) private view returns (uint256) {
        uint256 tokenDecimals = IERC20Metadata(token).decimals();

        // If oracle is unavailable, return token-denominated amount as a non-zero fallback.
        if (strataxOracleAddr == address(0)) {
            return amount;
        }

        uint256 tokenPrice = IStrataxOracle(strataxOracleAddr).getPrice(token);
        if (tokenPrice == 0) {
            return amount;
        }

        return (amount * tokenPrice) / (10 ** tokenDecimals);
    }
}
