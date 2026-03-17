// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Stratax} from "../../src/core/Stratax.sol";
import {StrataxManagedVault} from "../../src/core/StrataxManagedVault.sol";
import {IFeeCollector} from "../../src/interfaces/internal/IFeeCollector.sol";
import {IStrataxOracle} from "../../src/interfaces/internal/IStrataxOracle.sol";
import {IPool} from "../../src/interfaces/external/IPool.sol";
import {StrataxCalculations} from "../../src/libraries/StrataxCalculations.sol";
import {StrataxForkTestBase} from "./Base.t.sol";

/**
 * @title StrataxManagedVaultForkTest
 * @notice Fork tests for StrataxManagedVault integration with Stratax
 * @dev Run with: forge test --match-contract StrataxManagedVaultForkTest
 */
contract StrataxManagedVaultForkTest is StrataxForkTestBase {
    StrataxManagedVault public vault;

    address public manager;
    address public investor;

    uint256 internal constant DEPOSIT_AMOUNT = 2_000e6; // 2000 USDC

    function setUp() public override {
        super.setUp();

        manager = makeAddr("manager");
        investor = makeAddr("investor");

        vault = new StrataxManagedVault(address(stratax), manager, "Stratax Managed Vault USDC", "smvUSDC");
    }

    function test_DepositAndRedeem_MintsAndBurnsShares() public {
        _transferPositionToVaultOwner();

        uint256 shares = _depositIntoVault(DEPOSIT_AMOUNT);

        assertEq(shares, DEPOSIT_AMOUNT, "First deposit should mint 1:1 shares");
        assertEq(vault.balanceOf(investor), shares, "Investor should receive shares");

        uint256 redeemShares = shares / 2;
        uint256 usdcBefore = IERC20(USDC).balanceOf(investor);

        vm.prank(investor);
        uint256 redeemedAssets = vault.redeem(redeemShares, investor);

        uint256 usdcAfter = IERC20(USDC).balanceOf(investor);

        assertEq(usdcAfter - usdcBefore, redeemedAssets, "Redeem should transfer returned assets");
        assertEq(vault.balanceOf(investor), shares - redeemShares, "Shares should be burned on redeem");
    }

    function test_Pause_BlocksDeposits() public {
        _transferPositionToVaultOwner();

        vm.prank(manager);
        vault.setPause(true);

        deal(USDC, investor, DEPOSIT_AMOUNT);

        vm.startPrank(investor);
        IERC20(USDC).approve(address(vault), DEPOSIT_AMOUNT);
        vm.expectRevert("Vault is paused");
        vault.deposit(DEPOSIT_AMOUNT, investor);
        vm.stopPrank();
    }

    function test_Deactivate_BlocksNewDepositsAndLeverageIncrease() public {
        _transferPositionToVaultOwner();

        vm.prank(manager);
        vault.deactivate();

        deal(USDC, investor, DEPOSIT_AMOUNT);
        vm.startPrank(investor);
        IERC20(USDC).approve(address(vault), DEPOSIT_AMOUNT);
        vm.expectRevert("Vault is paused");
        vault.deposit(DEPOSIT_AMOUNT, investor);
        vm.stopPrank();

        vm.prank(manager);
        vm.expectRevert("Vault is paused");
        vault.increaseLeverageToTarget("", 0);
    }

    function test_WithdrawalQueue_RequestAndProcess() public {
        _transferPositionToVaultOwner();

        uint256 shares = _depositIntoVault(DEPOSIT_AMOUNT);

        uint256 requestShares = shares / 2;
        uint256 expectedAssets = vault.previewRedeem(requestShares);
        uint256 investorUsdcBefore = IERC20(USDC).balanceOf(investor);

        vm.prank(investor);
        uint256 requestId = vault.requestWithdrawal(requestShares, investor);

        assertEq(vault.balanceOf(investor), shares - requestShares, "Shares should be burned when queuing");
        assertEq(vault.totalPendingWithdrawals(), requestShares, "Pending withdrawals should track queued shares");

        // Overfund idle collateral because queue settlement value is computed at processing time.
        deal(USDC, address(vault), expectedAssets * 3);

        vm.prank(manager);
        uint256 processed = vault.processWithdrawalQueue(10);

        assertEq(processed, 1, "One request should be processed");

        (address owner, address receiver, uint256 storedShares, bool processedFlag, bool canceledFlag) =
            vault.withdrawalRequests(requestId);
        assertEq(owner, investor, "Request owner should match investor");
        assertEq(receiver, investor, "Request receiver should match investor");
        assertEq(storedShares, requestShares, "Stored request shares should match");
        assertTrue(processedFlag, "Request should be marked processed");
        assertTrue(!canceledFlag, "Request should not be canceled");
        assertEq(vault.totalPendingWithdrawals(), 0, "Pending withdrawals should decrease after processing");
        assertTrue(IERC20(USDC).balanceOf(investor) > investorUsdcBefore, "Investor should receive queued assets");
    }

    function test_WithdrawalQueue_CancelPendingRequest() public {
        _transferPositionToVaultOwner();

        uint256 shares = _depositIntoVault(DEPOSIT_AMOUNT);
        uint256 requestShares = shares / 3;

        vm.prank(investor);
        uint256 requestId = vault.requestWithdrawal(requestShares, investor);

        assertEq(vault.totalPendingWithdrawals(), requestShares, "Pending shares should increase on request");
        assertEq(vault.balanceOf(investor), shares - requestShares, "Shares should be burned on request");

        vm.prank(investor);
        uint256 restoredShares = vault.cancelWithdrawalRequest(requestId);

        assertEq(restoredShares, requestShares, "Canceled request should restore original shares");
        assertEq(vault.totalPendingWithdrawals(), 0, "Pending shares should decrease on cancel");
        assertEq(vault.balanceOf(investor), shares, "Investor shares should be restored after cancel");

        (address owner, address receiver, uint256 storedShares, bool processedFlag, bool canceledFlag) =
            vault.withdrawalRequests(requestId);
        assertEq(owner, investor, "Request owner should be investor");
        assertEq(receiver, investor, "Request receiver should be investor");
        assertEq(storedShares, requestShares, "Stored request shares should match");
        assertTrue(!processedFlag, "Canceled request should not be processed");
        assertTrue(canceledFlag, "Request should be marked canceled");
    }

    function test_IncreaseLeverageToTarget_RevertsWhenUsingFreeCollateralOnly() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        _transferPositionToVaultOwner();
        _depositIntoVault(DEPOSIT_AMOUNT);

        uint256 target = 20_000; // 2x

        vm.prank(manager);
        vault.setTargetLeverage(target);

        (, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: target, collateralAmount: 0, collateralTokenPrice: 0, borrowTokenPrice: 0
            })
        );

        (bytes memory openSwapData,) = get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        vm.prank(manager);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vault.increaseLeverageToTarget(openSwapData, 0);
    }

    function test_UnwindPositionToTarget() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        uint256 collateralAmount = 2_000e6;
        uint256 openTarget = 22_000; // 2.2x
        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: openTarget,
                collateralAmount: collateralAmount,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
            })
        );

        (bytes memory openSwapData,) = get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        deal(USDC, ownerTrader, collateralAmount);
        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateralAmount);
        stratax.createLeveragedPosition(flashLoanAmount, collateralAmount, borrowAmount, openSwapData, 0);
        vm.stopPrank();

        _transferPositionToVaultOwner();

        uint256 leverageBefore = stratax.getCurrentLeverage();

        uint256 unwindTarget = 15_000; // 1.5x

        vm.prank(manager);
        vault.setTargetLeverage(unwindTarget);

        uint256 debtToRepay = _calculateDebtToRepayForTarget(leverageBefore, unwindTarget);
        (uint256 collateralToWithdraw,,) = stratax.calculateUnwindParams(debtToRepay);

        (bytes memory unwindSwapData,) = get1inchSwapData(USDC, WETH, collateralToWithdraw, address(stratax));

        vm.prank(manager);
        vault.unwindPositionToTarget(unwindSwapData, 0);

        uint256 leverageAfter = stratax.getCurrentLeverage();

        assertTrue(leverageAfter < leverageBefore, "Leverage should decrease after unwind");
        assertTrue(leverageAfter <= unwindTarget + 500, "Leverage should be at or below target with small tolerance");
    }

    function test_DeactivateThenUnwindAndProcessQueuedWithdrawals() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        uint256 ownerCollateralAmount = 2_000e6;
        uint256 desiredLeverage = 22_000;
        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
                collateralAmount: ownerCollateralAmount,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
            })
        );

        (bytes memory openSwapData,) = get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        deal(USDC, ownerTrader, ownerCollateralAmount);
        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), ownerCollateralAmount);
        stratax.createLeveragedPosition(flashLoanAmount, ownerCollateralAmount, borrowAmount, openSwapData, 0);
        vm.stopPrank();

        (, uint256 debtBefore,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));
        assertTrue(debtBefore > 0, "Position should be leveraged");

        _transferPositionToVaultOwner();

        uint256 shares = _depositIntoVault(DEPOSIT_AMOUNT);
        uint256 requestShares = shares / 2;
        uint256 expectedAssets = vault.previewRedeem(requestShares);

        vm.prank(investor);
        uint256 requestId = vault.requestWithdrawal(requestShares, investor);

        assertEq(vault.totalPendingWithdrawals(), requestShares, "Pending withdrawals should include queued shares");

        vm.prank(manager);
        vault.deactivate();

        (uint256 collateralToWithdraw,,) = stratax.calculateUnwindParams(type(uint256).max);
        (bytes memory unwindSwapData,) = get1inchSwapData(USDC, WETH, collateralToWithdraw, address(stratax));

        vm.prank(manager);
        vault.unwindPosition(type(uint256).max, unwindSwapData, 0);

        // Queue processor pays from idle collateral held by the vault.
        uint256 idleCollateral = IERC20(USDC).balanceOf(address(vault));
        if (idleCollateral < expectedAssets) {
            deal(USDC, address(vault), expectedAssets * 3);
        }

        vm.prank(manager);
        uint256 processed = vault.processWithdrawalQueue(10);

        assertEq(processed, 1, "Queued withdrawal should be processed");
        (,, uint256 storedShares, bool processedFlag,) = vault.withdrawalRequests(requestId);
        assertEq(storedShares, requestShares, "Queued shares should match request");
        assertTrue(processedFlag, "Request should be marked processed");
        assertEq(vault.totalPendingWithdrawals(), 0, "Pending withdrawals should be cleared after processing");
    }

    function _transferPositionToVaultOwner() internal {
        if (strataxPositionNft.ownerOf(tokenId) != address(vault)) {
            vm.prank(ownerTrader);
            strataxPositionNft.transferFrom(ownerTrader, address(vault), tokenId);
        }
    }

    function _depositIntoVault(uint256 assets) internal returns (uint256 shares) {
        deal(USDC, investor, assets);

        vm.startPrank(investor);
        IERC20(USDC).approve(address(vault), assets);
        shares = vault.deposit(assets, investor);
        vm.stopPrank();
    }

    function _calculateDebtToRepayForTarget(uint256 currentLeverage, uint256 target)
        internal
        view
        returns (uint256 debtToRepay)
    {
        uint256 positionUsdValue = stratax.getPositionUsdValue();
        uint256 leverageDelta = currentLeverage - target;
        uint256 debtRepayUsdValue = (positionUsdValue * leverageDelta) / StrataxCalculations.LEVERAGE_PRECISION;

        uint256 feeBps = stratax.flashLoanFeeBps() + IFeeCollector(stratax.feeCollector()).strataxFee();
        uint256 denominator = StrataxCalculations.FLASHLOAN_FEE_PREC * StrataxCalculations.LEVERAGE_PRECISION;

        if (target > StrataxCalculations.LEVERAGE_PRECISION && feeBps > 0) {
            uint256 feeAdjustment = feeBps * (target - StrataxCalculations.LEVERAGE_PRECISION);
            denominator -= feeAdjustment;
        }

        debtRepayUsdValue =
            (debtRepayUsdValue
                    * StrataxCalculations.FLASHLOAN_FEE_PREC
                    * StrataxCalculations.LEVERAGE_PRECISION
                    + denominator
                    - 1) / denominator;

        uint256 borrowTokenPriceUsd = IStrataxOracle(stratax.strataxOracle()).getPrice(stratax.borrowToken());

        debtToRepay =
            (debtRepayUsdValue * (10 ** stratax.borrowTokenDecimals()) + borrowTokenPriceUsd - 1) / borrowTokenPriceUsd;
    }
}
