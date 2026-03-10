// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Stratax} from "../../src/Stratax.sol";
import {StrataxPositionNft} from "../../src/StrataxPositionNft.sol";
import {IPool} from "../../src/interfaces/external/IPool.sol";
import {IProtocolDataProvider} from "../../src/interfaces/external/IProtocolDataProvider.sol";
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

            // Extract and log the function selector
            bytes4 selector = stratax.extractSelector(swapData);
            console.log("1inch function selector:");
            console.logBytes4(selector);
        }
    }

    function test_Example_SwapWithRealData() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        uint256 collateralAmount = 1000 * 10 ** 6;
        uint256 desiredLeverage = 38939;

        //uint256 desiredLeverage = 30_000;
        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
                collateralAmount: collateralAmount,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
            })
        );

        (bytes memory swapData,) = get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        // Extract and log the function selector before attempting swap
        bytes4 selector = stratax.extractSelector(swapData);
        console.log("1inch function selector:");
        console.logBytes4(selector);
        console.log("As hex:");
        console.logBytes(abi.encodePacked(selector));

        deal(USDC, ownerTrader, collateralAmount);

        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateralAmount);
        stratax.createLeveragedPosition(
            flashLoanAmount, collateralAmount, borrowAmount, swapData, (flashLoanAmount * 950) / 1000
        );
        vm.stopPrank();
        console.log("Position leverage after open:", stratax.getCurrentLeverage());

        _verifyPosition(address(stratax));
    }

    function test_OpenAndUnwindPosition() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        // Open position
        uint256 desiredLeverage = 30_000; // 3x leverage
        uint256 collateralAmount = 1000 * 10 ** 6;
        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
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

    function test_MintAndOpenPositionInOneCall() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        // Setup for minting a new position and opening it simultaneously
        address newPositionOwner = address(0x9999);
        address collateralToken = USDC;
        address borrowToken = WETH;
        uint256 collateralAmount = 2000 * 10 ** 6; // 2000 USDC
        uint256 desiredLeverage = 25_000; // 2.5x leverage

        // Calculate initial open parameters using the StrataxPositionNft function
        (uint256 flashLoanAmount, uint256 borrowAmount, uint256 strataxFee) =
            strataxPositionNft.calculateInitOpenParams(collateralToken, borrowToken, collateralAmount, desiredLeverage);

        console.log("Flash loan amount:", flashLoanAmount);
        console.log("Borrow amount:", borrowAmount);
        console.log("Stratax fee:", strataxFee);

        // Predict the stratax proxy address that will be deployed
        uint256 nextTokenId = strataxPositionNft.getTotalPositionsCreated() + 1;
        address predictedProxy =
            strataxPositionNft.predictStrataxProxyAddress(newPositionOwner, nextTokenId, collateralToken, borrowToken);

        console.log("Predicted Stratax proxy address:", predictedProxy);

        // Get swap data for the predicted proxy address
        (bytes memory swapData, uint256 expectedReturnAmount) =
            get1inchSwapData(borrowToken, collateralToken, borrowAmount, predictedProxy);

        console.log("Expected return amount from swap:", expectedReturnAmount);

        // Prepare InitPositionParams
        StrataxPositionNft.InitPositionParams memory initParams = StrataxPositionNft.InitPositionParams({
            flashLoanAmount: flashLoanAmount,
            collateralAmount: collateralAmount,
            borrowAmount: borrowAmount,
            oneInchSwapData: swapData,
            minReturnAmount: (flashLoanAmount * 950) / 1000 // 5% slippage tolerance
        });

        // Give the new owner the collateral
        deal(collateralToken, newPositionOwner, collateralAmount);

        // Mint position NFT and open position in one transaction
        vm.startPrank(newPositionOwner);
        IERC20(collateralToken).approve(address(strataxPositionNft), collateralAmount);

        (uint256 mintedTokenId, address deployedStrataxProxy) =
            strataxPositionNft.mintPositionNft(newPositionOwner, collateralToken, borrowToken, true, initParams);

        vm.stopPrank();

        // Verify the deployment
        assertEq(deployedStrataxProxy, predictedProxy, "Deployed address should match predicted address");
        assertEq(mintedTokenId, nextTokenId, "Token ID should match prediction");
        assertEq(strataxPositionNft.ownerOf(mintedTokenId), newPositionOwner, "NFT should be owned by new owner");

        // Verify the position was opened successfully
        Stratax newStratax = Stratax(deployedStrataxProxy);
        (uint256 totalCollateral, uint256 totalDebt,,,, uint256 healthFactor) =
            IPool(AAVE_POOL).getUserAccountData(deployedStrataxProxy);

        console.log("Total collateral (USD, 8 decimals):", totalCollateral);
        console.log("Total debt (USD, 8 decimals):", totalDebt);
        console.log("Health factor:", healthFactor);

        assertTrue(totalCollateral > 0, "Should have collateral");
        assertTrue(totalDebt > 0, "Should have debt");
        assertTrue(healthFactor > 1e18, "Health factor should be above 1");

        // Verify leverage approximates desired leverage
        // Actual leverage = totalCollateral / (totalCollateral - totalDebt)
        uint256 actualLeverageApprox = (totalCollateral * 10_000) / (totalCollateral - totalDebt);
        console.log("Actual leverage (approx with precision):", actualLeverageApprox);

        uint256 altLeverageCalculation = Stratax(deployedStrataxProxy).getCurrentLeverage();
        console.log("Actual leverage from Stratax function:", altLeverageCalculation);
        console.log("Collateral token balance in Stratax:", IERC20(collateralToken).balanceOf(deployedStrataxProxy));
        console.log("Borrow token balance in Stratax:", IERC20(borrowToken).balanceOf(deployedStrataxProxy));
        console.log("Position USD value is: ", Stratax(deployedStrataxProxy).getPositionUsdValue());

        /*         // Allow some variance due to swap slippage and fees
                assertTrue(
                    actualLeverageApprox >= desiredLeverage - 2000 && actualLeverageApprox <= desiredLeverage + 2000,
                    "Leverage should be close to desired leverage"
                ); */

        // Verify contract state
        assertEq(newStratax.collateralToken(), collateralToken, "Collateral token should match");
        assertEq(newStratax.borrowToken(), borrowToken, "Borrow token should match");
        assertEq(newStratax.tokenId(), mintedTokenId, "Token ID should match");
    }

    function test_PartialUnwindPosition() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        // Open position first
        uint256 desiredLeverage = 30_000; // 3x leverage
        uint256 collateralAmount = 1000 * 10 ** 6;
        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
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
        //currently open debt
        (,, address variableDebtToken) =
            IProtocolDataProvider(stratax.aaveDataProvider()).getReserveTokensAddresses(stratax.borrowToken());

        uint256 debtTokenAmount = IERC20(variableDebtToken).balanceOf(address(stratax));
        (uint256 totalCollateralBefore, uint256 totalDebtBefore,,,,) =
            IPool(AAVE_POOL).getUserAccountData(address(stratax));

        // Partially unwind 50% of the debt
        uint256 partialDebt = totalDebtBefore / 2;
        (
            uint256 collateralToWithdraw,
            uint256 debtAmount, /* uint256 strataxFee */
        ) = stratax.calculateUnwindParams(partialDebt);

        (bytes memory unwindSwapData,) = get1inchSwapData(USDC, WETH, collateralToWithdraw, address(stratax));

        // Extract and log the function selector for unwind swap
        bytes4 unwindSelector = stratax.extractSelector(unwindSwapData);
        console.log("Unwind swap selector:");
        console.logBytes4(unwindSelector);

        stratax.unwindPosition(collateralToWithdraw, debtAmount, unwindSwapData, (debtAmount * 950) / 1000);

        vm.stopPrank();

        (uint256 totalCollateralAfter, uint256 totalDebtAfter,,,,) =
            IPool(AAVE_POOL).getUserAccountData(address(stratax));

        assertTrue(totalDebtAfter < totalDebtBefore, "Debt should be reduced");
        assertTrue(totalDebtAfter > 0, "Position should still have debt");
        assertTrue(totalCollateralAfter < totalCollateralBefore, "Collateral should be reduced");
        assertTrue(totalCollateralAfter > 0, "Position should still have collateral");
    }

    function test_IncreasePosition() public {
        // TODO: Implement position increase functionality in Stratax contract
        vm.skip(true);
    }

    function test_RepayDebt() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        // Open position
        uint256 collateralAmount = 1000 * 10 ** 6;
        uint256 desiredLeverage = 30_000;

        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
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

        (, uint256 totalDebtBefore,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));

        // Repay some debt
        uint256 repayAmount = 0.1 ether; // 0.1 WETH
        deal(WETH, ownerTrader, repayAmount);
        IERC20(WETH).approve(address(stratax), repayAmount);
        stratax.repayDebtToken(repayAmount);

        vm.stopPrank();

        (, uint256 totalDebtAfter,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));

        assertTrue(totalDebtAfter < totalDebtBefore, "Debt should decrease after repayment");
    }

    function test_BorrowMore() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        // Open position with lower leverage
        uint256 collateralAmount = 2000 * 10 ** 6;
        uint256 desiredLeverage = 20_000; // 2x leverage - low enough to allow more borrowing

        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
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

        (, uint256 totalDebtBefore,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));

        // Borrow more
        uint256 additionalBorrow = 0.1 ether;
        stratax.borrowDebtToken(additionalBorrow);

        vm.stopPrank();

        (, uint256 totalDebtAfter,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));

        assertTrue(totalDebtAfter > totalDebtBefore, "Debt should increase after borrowing more");
        assertTrue(IERC20(WETH).balanceOf(address(ownerTrader)) >= additionalBorrow, "Should have borrowed tokens");
    }

    function test_UnwindFullPositionAndBurnNFT() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        // Open position
        uint256 collateralAmount = 1000 * 10 ** 6;
        uint256 desiredLeverage = 25_000;

        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
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

        assertTrue(strataxPositionNft.exists(tokenId), "NFT should exist before full unwind");

        // Fully unwind position (unwind all debt)
        (
            uint256 collateralToWithdraw,
            uint256 debtAmount, /* uint256 strataxFee */
        ) = stratax.calculateUnwindParams(type(uint256).max);

        (bytes memory unwindSwapData,) = get1inchSwapData(USDC, WETH, collateralToWithdraw, address(stratax));
        stratax.unwindPosition(collateralToWithdraw, debtAmount, unwindSwapData, (debtAmount * 950) / 1000);

        vm.stopPrank();

        // Verify position is fully unwound
        (, uint256 totalDebt,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));
        assertEq(totalDebt, 0, "Debt should be zero after full unwind");
    }

    function test_MaxLeveragePosition() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        // Try to open position at near-max leverage
        uint256 collateralAmount = 2000 * 10 ** 6;

        // Get the actual max achievable leverage
        uint256 maxLeverage = stratax.getMaxAchievableLeverageBinary();

        console.log("Max achievable leverage:", maxLeverage);

        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: maxLeverage,
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
        vm.stopPrank();

        (,,,, uint256 ltv_, uint256 healthFactor) = IPool(AAVE_POOL).getUserAccountData(address(stratax));

        console.log("Health factor:", healthFactor);
        console.log("LTV (basis points):", ltv_);

        assertTrue(healthFactor > 1e18, "Health factor should be above 1 even at max leverage");
        assertTrue(healthFactor < 1.15e18, "Health factor should be close to minimum for max leverage");
    }

    function test_MultiplePositionsSameOwner() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        address trader = makeAddr("multiPositionTrader");

        // Create first position: USDC collateral, WETH borrow (long ETH)
        StrataxPositionNft.InitPositionParams memory emptyParams1;
        (uint256 tokenId1, address strataxProxy1) =
            strataxPositionNft.mintPositionNft(trader, USDC, WETH, false, emptyParams1);

        // Create second position: WETH collateral, USDC borrow (short ETH)
        StrataxPositionNft.InitPositionParams memory emptyParams2;
        (uint256 tokenId2, address strataxProxy2) =
            strataxPositionNft.mintPositionNft(trader, WETH, USDC, false, emptyParams2);

        // Verify NFTs
        assertEq(strataxPositionNft.ownerOf(tokenId1), trader);
        assertEq(strataxPositionNft.ownerOf(tokenId2), trader);
        assertEq(strataxPositionNft.balanceOf(trader), 2);

        // Verify positions are different
        assertTrue(strataxProxy1 != strataxProxy2, "Proxies should have different addresses");
        assertEq(Stratax(strataxProxy1).collateralToken(), USDC);
        assertEq(Stratax(strataxProxy1).borrowToken(), WETH);
        assertEq(Stratax(strataxProxy2).collateralToken(), WETH);
        assertEq(Stratax(strataxProxy2).borrowToken(), USDC);

        // Open both positions
        uint256 collateralAmount1 = 1000 * 10 ** 6; // 1000 USDC
        (uint256 flashLoan1, uint256 borrow1) = Stratax(strataxProxy1)
            .calculateOpenParams(
                Stratax.CalcOpenParams({
                desiredLeverage: 25_000,
                collateralAmount: collateralAmount1,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
            })
            );

        (bytes memory swap1,) = get1inchSwapData(WETH, USDC, borrow1, strataxProxy1);

        deal(USDC, trader, collateralAmount1);
        vm.startPrank(trader);
        IERC20(USDC).approve(strataxProxy1, collateralAmount1);
        Stratax(strataxProxy1)
            .createLeveragedPosition(flashLoan1, collateralAmount1, borrow1, swap1, (flashLoan1 * 950) / 1000);
        vm.stopPrank();

        uint256 collateralAmount2 = 0.5 ether; // 0.5 WETH
        (uint256 flashLoan2, uint256 borrow2) = Stratax(strataxProxy2)
            .calculateOpenParams(
                Stratax.CalcOpenParams({
                desiredLeverage: 20_000,
                collateralAmount: collateralAmount2,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
            })
            );

        (bytes memory swap2,) = get1inchSwapData(USDC, WETH, borrow2, strataxProxy2);

        deal(WETH, trader, collateralAmount2);
        vm.startPrank(trader);
        IERC20(WETH).approve(strataxProxy2, collateralAmount2);
        Stratax(strataxProxy2)
            .createLeveragedPosition(flashLoan2, collateralAmount2, borrow2, swap2, (flashLoan2 * 950) / 1000);
        vm.stopPrank();

        // Verify both positions are active
        (uint256 collateral1, uint256 debt1,,,,) = IPool(AAVE_POOL).getUserAccountData(strataxProxy1);
        (uint256 collateral2, uint256 debt2,,,,) = IPool(AAVE_POOL).getUserAccountData(strataxProxy2);

        assertTrue(collateral1 > 0 && debt1 > 0, "Position 1 should be active");
        assertTrue(collateral2 > 0 && debt2 > 0, "Position 2 should be active");
    }

    function test_EmergencyWithdraw() public {
        // TODO: Implement emergency withdraw functionality in Stratax contract
        vm.skip(true);
    }

    function test_FeeCollection() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        uint256 feeCollectorBalanceBefore = IERC20(USDC).balanceOf(address(feeCollector));

        // Open position (which should pay fees)
        uint256 collateralAmount = 1000 * 10 ** 6;
        uint256 desiredLeverage = 25_000;

        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
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
        vm.stopPrank();

        uint256 feeCollectorBalanceAfter = IERC20(USDC).balanceOf(address(feeCollector));

        assertTrue(feeCollectorBalanceAfter > feeCollectorBalanceBefore, "Fee collector should have received fees");
        console.log("Fees collected:", feeCollectorBalanceAfter - feeCollectorBalanceBefore);
    }

    function test_OracleIntegration() public {
        // Test oracle prices
        uint256 usdcPrice = strataxOracle.getPrice(USDC);
        uint256 wethPrice = strataxOracle.getPrice(WETH);

        console.log("USDC price (8 decimals):", usdcPrice);
        console.log("WETH price (8 decimals):", wethPrice);

        // USDC should be close to $1 (1e8 with 8 decimals)
        assertTrue(usdcPrice > 0.99e8 && usdcPrice < 1.01e8, "USDC price should be close to $1");

        // WETH should be reasonable (at least $1000)
        assertTrue(wethPrice > 1000e8, "WETH price should be reasonable");
    }

    function test_PositionHealthFactorTracking() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        // Open position
        uint256 collateralAmount = 1000 * 10 ** 6;
        uint256 desiredLeverage = 30_000;

        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
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

        (,,,,, uint256 healthFactorInitial) = IPool(AAVE_POOL).getUserAccountData(address(stratax));
        console.log("Initial health factor:", healthFactorInitial);

        // Repay some debt to improve health factor
        uint256 repayAmount = 0.05 ether;
        deal(WETH, ownerTrader, repayAmount);
        IERC20(WETH).approve(address(stratax), repayAmount);
        stratax.repayDebtToken(repayAmount);

        (,,,,, uint256 healthFactorAfterRepay) = IPool(AAVE_POOL).getUserAccountData(address(stratax));
        console.log("Health factor after repay:", healthFactorAfterRepay);

        assertTrue(healthFactorAfterRepay > healthFactorInitial, "Health factor should improve after repayment");

        vm.stopPrank();
    }

    function test_CalculateDesiredLeverage() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        // Open position
        uint256 collateralAmount = 1000 * 10 ** 6;
        uint256 desiredLeverage = 25_000; // 2.5x

        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
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
        vm.stopPrank();

        // Calculate what the desired leverage would be for current position
        uint256 calculatedDesiredLeverage = stratax.calculateDesiredLeverage(flashLoanAmount, collateralAmount);

        console.log("Original desired leverage:", desiredLeverage);
        console.log("Calculated desired leverage:", calculatedDesiredLeverage);

        // Should be close (within 5% due to fees and slippage)
        uint256 diff = desiredLeverage > calculatedDesiredLeverage
            ? desiredLeverage - calculatedDesiredLeverage
            : calculatedDesiredLeverage - desiredLeverage;
        assertTrue(diff < desiredLeverage / 20, "Calculated leverage should be close to original");
    }
}
