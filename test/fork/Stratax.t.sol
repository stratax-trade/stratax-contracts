// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Stratax} from "../../src/Stratax.sol";
import {IPool} from "../../src/interfaces/external/IPool.sol";
import {StrataxForkTestBase} from "./Base.t.sol";

/**
 * @title StrataxForkTest
 * @notice Fork tests for Stratax leveraged positions
 * @dev Run with: forge test --match-contract StrataxForkTest
 */
contract StrataxForkTest is StrataxForkTestBase {
    /*//////////////////////////////////////////////////////////////
                              TESTS
    //////////////////////////////////////////////////////////////*/

    function test_USDCTokenExists() public view {
        uint256 totalSupply = IERC20(USDC).totalSupply();
        assertTrue(totalSupply > 0, "USDC total supply should be greater than 0");
    }

    function test_FFI_Get1inchSwapData() public {
        if (!hasApiKey) {
            vm.skip(true);
        }

        uint256 swapAmount = 1000 * 10 ** 6;
        (bytes memory swapData, uint256 expectedAmount) = get1inchSwapData(USDC, WETH, swapAmount, address(stratax));

        if (swapData.length > 0) {
            assertTrue(expectedAmount > 0, "Expected amount should be greater than 0");
        }
    }

    function test_Example_SwapWithRealData() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        uint256 collateralAmount = 1000 * 10 ** 6;
        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: 30_000,
                collateralAmount: collateralAmount,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
            })
        );

        (bytes memory swapData,) = get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        deal(USDC, ownerTrader, collateralAmount);

        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateralAmount);
        stratax.createLeveragedPosition(
            flashLoanAmount, collateralAmount, borrowAmount, swapData, (flashLoanAmount * 950) / 1000
        );
        vm.stopPrank();

        _verifyPosition(address(stratax));
    }

    function test_OpenAndUnwindPosition() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        // Open position
        uint256 collateralAmount = 1000 * 10 ** 6;
        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: 30_000,
                collateralAmount: collateralAmount,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
            })
        );

        (bytes memory openSwapData,) = get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        deal(USDC, ownerTrader, collateralAmount);

        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateralAmount);
        stratax.createLeveragedPosition(
            flashLoanAmount, collateralAmount, borrowAmount, openSwapData, (flashLoanAmount * 950) / 1000
        );

        (uint256 totalCollateralAfterOpen, uint256 totalDebtAfterOpen,,,, uint256 healthFactorAfterOpen) =
            IPool(AAVE_POOL).getUserAccountData(address(stratax));

        assertTrue(totalCollateralAfterOpen > 0, "Should have collateral");
        assertTrue(totalDebtAfterOpen > 0, "Should have debt");
        assertTrue(healthFactorAfterOpen > 1e18, "Health factor should be above 1");

        // Unwind position
        console.log("Unwind: calculating params");
        (
            uint256 collateralToWithdraw,
            uint256 debtAmount, /* uint256 strataxFee */
        ) = stratax.calculateUnwindParams(type(uint256).max);
        console.log("Unwind: get 1inch data");
        (bytes memory unwindSwapData,) = get1inchSwapData(USDC, WETH, collateralToWithdraw, address(stratax));
        console.log("Unwind: calling stratax to unwind position");
        stratax.unwindPosition(collateralToWithdraw, debtAmount, unwindSwapData, (debtAmount * 950) / 1000);

        vm.stopPrank();

        (, uint256 totalDebtAfterUnwind,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));

        assertTrue(totalDebtAfterUnwind < totalDebtAfterOpen, "Debt should be reduced");
        assertTrue(
            IERC20(USDC).balanceOf(ownerTrader) > 0 || IERC20(WETH).balanceOf(ownerTrader) > 0,
            "User should receive tokens back"
        );
    }
}
