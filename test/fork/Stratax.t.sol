// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Stratax_Aave_1Inch as Stratax} from "../../src/core/position-types/Stratax_Aave_1Inch.sol";
import {StrataxPositionNft} from "../../src/core/StrataxPositionNft.sol";
import {StrataxRouter} from "../../src/core/StrataxRouter.sol";
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
        uint256 desiredLeverage = 20_000; // 2x leverage for more unwind buffer
        uint256 collateralAmount = 1000 * 10 ** 6;
        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
                collateralAmount: collateralAmount,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
            })
        );

        (bytes memory openSwapData, uint256 openExpectedAmount) =
            get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        deal(USDC, ownerTrader, collateralAmount);

        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateralAmount);
        stratax.createLeveragedPosition(
            flashLoanAmount, collateralAmount, borrowAmount, openSwapData, (openExpectedAmount * 97) / 100
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
        collateralToWithdraw = (collateralToWithdraw * 103) / 100;
        console.log("Unwind: get 1inch data");
        (bytes memory unwindSwapData, uint256 unwindExpectedAmount) =
            get1inchSwapData(USDC, WETH, collateralToWithdraw, address(stratax));
        console.log("Unwind: calling stratax to unwind position");
        stratax.unwindPosition(collateralToWithdraw, debtAmount, unwindSwapData, 0);

        vm.stopPrank();

        (, uint256 totalDebtAfterUnwind,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));

        assertTrue(totalDebtAfterUnwind < totalDebtAfterOpen, "Debt should be reduced");
        assertTrue(
            IERC20(USDC).balanceOf(ownerTrader) > 0 || IERC20(WETH).balanceOf(ownerTrader) > 0,
            "User should receive tokens back"
        );
    }

    function test_MintAndOpenPositionInOneCall() public {
        // Setup
        address newPositionOwner = address(0x9999);
        address collateralToken = USDC;
        address borrowToken = WETH;
        uint256 collateralAmount = 2000 * 10 ** 6; // 2000 USDC
        uint256 desiredLeverage = 25_000; // 2.5x leverage

        // Deploy router
        StrataxRouter router = new StrataxRouter(address(strataxPositionNft));

        // Calculate open params using the existing stratax position
        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
                collateralAmount: collateralAmount,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
            })
        );

        console.log("Flash loan amount:", flashLoanAmount);
        console.log("Borrow amount:", borrowAmount);

        // Predict proxy address via router (router is the caller to positionNft)
        address predictedProxy =
            router.predictNextProxyAddress(collateralToken, borrowToken, LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID);

        // Pre-fund predicted proxy so 1inch quote generation works
        deal(borrowToken, predictedProxy, borrowAmount);

        (bytes memory swapData, uint256 expectedReturnAmount) =
            get1inchSwapData(borrowToken, collateralToken, borrowAmount, predictedProxy);

        console.log("Expected return amount from swap:", expectedReturnAmount);

        // Mint + open via router
        deal(collateralToken, newPositionOwner, collateralAmount);

        vm.startPrank(newPositionOwner);
        IERC20(collateralToken).approve(address(router), collateralAmount);

        (uint256 mintedTokenId, address deployedStrataxProxy) = router.createAaveOneInchPosition(
            collateralToken, borrowToken, collateralAmount, flashLoanAmount, borrowAmount, swapData, 0
        );
        vm.stopPrank();

        // Verify the deployment
        assertTrue(deployedStrataxProxy != address(0), "Deployed address should be non-zero");
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

        uint256 altLeverageCalculation = Stratax(deployedStrataxProxy).getCurrentLeverage();
        console.log("Actual leverage from Stratax function:", altLeverageCalculation);
        console.log("Position USD value is: ", Stratax(deployedStrataxProxy).getPositionUsdValue());

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

        (bytes memory openSwapData, uint256 openExpectedAmount) =
            get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        deal(USDC, ownerTrader, collateralAmount);

        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateralAmount);
        stratax.createLeveragedPosition(
            flashLoanAmount, collateralAmount, borrowAmount, openSwapData, (openExpectedAmount * 97) / 100
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

        // Add a small buffer to account for swap/price movement in fork environments.
        collateralToWithdraw = (collateralToWithdraw * 102) / 100;

        (bytes memory unwindSwapData, uint256 unwindExpectedAmount) =
            get1inchSwapData(USDC, WETH, collateralToWithdraw, address(stratax));

        // Extract and log the function selector for unwind swap
        bytes4 unwindSelector = stratax.extractSelector(unwindSwapData);
        console.log("Unwind swap selector:");
        console.logBytes4(unwindSelector);

        stratax.unwindPosition(collateralToWithdraw, debtAmount, unwindSwapData, (unwindExpectedAmount * 92) / 100);

        vm.stopPrank();

        (uint256 totalCollateralAfter, uint256 totalDebtAfter,,,,) =
            IPool(AAVE_POOL).getUserAccountData(address(stratax));

        assertTrue(totalDebtAfter < totalDebtBefore, "Debt should be reduced");
        assertTrue(totalDebtAfter > 0, "Position should still have debt");
        assertTrue(totalCollateralAfter < totalCollateralBefore, "Collateral should be reduced");
        assertTrue(totalCollateralAfter > 0, "Position should still have collateral");
    }

    function test_IncreasePosition() public {
        uint256 suppliedCollateral = 2000 * 10 ** 6;
        uint256 additionalBorrow = 0.1 ether;

        deal(USDC, ownerTrader, suppliedCollateral);

        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), suppliedCollateral);
        stratax.supplyCollateral(suppliedCollateral);

        (uint256 collateralBeforeIncrease, uint256 debtBeforeIncrease,,,, uint256 healthBeforeIncrease) =
            IPool(AAVE_POOL).getUserAccountData(address(stratax));

        uint256 ownerWethBefore = IERC20(WETH).balanceOf(ownerTrader);
        stratax.borrowDebtToken(additionalBorrow);
        vm.stopPrank();

        (uint256 collateralAfterIncrease, uint256 debtAfterIncrease,,,, uint256 healthAfterIncrease) =
            IPool(AAVE_POOL).getUserAccountData(address(stratax));

        assertTrue(collateralAfterIncrease >= collateralBeforeIncrease, "Collateral should stay the same or increase");
        assertTrue(debtAfterIncrease > debtBeforeIncrease, "Debt should increase after borrowing");
        assertTrue(healthBeforeIncrease > 1e18, "Initial health factor should be above 1");
        assertTrue(healthAfterIncrease > 1e18, "Health factor should remain above 1 after position increase");
        assertTrue(
            IERC20(WETH).balanceOf(ownerTrader) >= ownerWethBefore + additionalBorrow,
            "Owner should receive additional borrowed WETH"
        );
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

        (bytes memory openSwapData, uint256 openExpectedAmount) =
            get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        deal(USDC, ownerTrader, collateralAmount);

        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateralAmount);
        stratax.createLeveragedPosition(
            flashLoanAmount, collateralAmount, borrowAmount, openSwapData, (openExpectedAmount * 97) / 100
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

        (bytes memory openSwapData, uint256 openExpectedAmount) =
            get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        deal(USDC, ownerTrader, collateralAmount);

        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateralAmount);
        stratax.createLeveragedPosition(
            flashLoanAmount, collateralAmount, borrowAmount, openSwapData, (openExpectedAmount * 97) / 100
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
        uint256 desiredLeverage = 20_000;

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
        collateralToWithdraw = (collateralToWithdraw * 103) / 100;

        (bytes memory unwindSwapData, uint256 unwindExpectedAmount) =
            get1inchSwapData(USDC, WETH, collateralToWithdraw, address(stratax));
        stratax.unwindPosition(collateralToWithdraw, debtAmount, unwindSwapData, 0);

        vm.stopPrank();

        // Verify position is fully unwound
        (, uint256 totalDebt,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));
        assertEq(totalDebt, 0, "Debt should be zero after full unwind");
    }

    function test_CalculateUnwindParamsWithSlippageBps_PartialUnwind() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

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

        (bytes memory openSwapData, uint256 openExpectedAmount) =
            get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        deal(USDC, ownerTrader, collateralAmount);

        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateralAmount);
        stratax.createLeveragedPosition(
            flashLoanAmount, collateralAmount, borrowAmount, openSwapData, (openExpectedAmount * 97) / 100
        );

        (, uint256 totalDebtBefore,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));

        uint256 partialDebtToRepay = totalDebtBefore / 2;
        (uint256 collateralDefault, uint256 debtDefault,) = stratax.calculateUnwindParams(partialDebtToRepay);

        uint256 customSlippageBps = 300; // 3%
        (uint256 collateralBuffered, uint256 debtAmount,) =
            stratax.calculateUnwindParams(partialDebtToRepay, customSlippageBps);

        assertEq(debtAmount, debtDefault, "Debt amount should match for same repay target");
        assertTrue(collateralBuffered > collateralDefault, "Buffered collateral should be greater than default");

        (bytes memory unwindSwapData,) = get1inchSwapData(USDC, WETH, collateralBuffered, address(stratax));
        stratax.unwindPosition(collateralBuffered, debtAmount, unwindSwapData, 0);
        vm.stopPrank();

        (, uint256 totalDebtAfter,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));
        assertTrue(totalDebtAfter < totalDebtBefore, "Debt should be reduced after partial unwind");
        assertTrue(totalDebtAfter > 0, "Partial unwind should leave remaining debt");
    }

    function test_CalculateUnwindParamsWithSlippageBps_FullUnwind() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        uint256 collateralAmount = 1000 * 10 ** 6;
        uint256 desiredLeverage = 20_000;

        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
                collateralAmount: collateralAmount,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
            })
        );

        (bytes memory openSwapData, uint256 openExpectedAmount) =
            get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        deal(USDC, ownerTrader, collateralAmount);

        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateralAmount);
        stratax.createLeveragedPosition(
            flashLoanAmount, collateralAmount, borrowAmount, openSwapData, (openExpectedAmount * 97) / 100
        );

        (uint256 collateralDefault, uint256 debtDefault,) = stratax.calculateUnwindParams(type(uint256).max);

        uint256 customSlippageBps = 300; // 3%
        (uint256 collateralBuffered, uint256 debtAmount,) =
            stratax.calculateUnwindParams(type(uint256).max, customSlippageBps);

        assertEq(debtAmount, debtDefault, "Debt amount should match for full unwind");
        assertTrue(collateralBuffered > collateralDefault, "Buffered collateral should be greater than default");

        (bytes memory unwindSwapData,) = get1inchSwapData(USDC, WETH, collateralBuffered, address(stratax));
        stratax.unwindPosition(collateralBuffered, debtAmount, unwindSwapData, 0);
        vm.stopPrank();

        (, uint256 totalDebtAfter,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));
        assertEq(totalDebtAfter, 0, "Debt should be zero after full unwind");
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
        (uint256 tokenId1, address strataxProxy1) =
            strataxPositionNft.mintPosition(trader, USDC, WETH, LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID);

        // Create second position: WETH collateral, USDC borrow (short ETH)
        (uint256 tokenId2, address strataxProxy2) =
            strataxPositionNft.mintPosition(trader, WETH, USDC, LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID);

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

        (bytes memory swap1, uint256 expectedSwap1) = get1inchSwapData(WETH, USDC, borrow1, strataxProxy1);

        deal(USDC, trader, collateralAmount1);
        vm.startPrank(trader);
        IERC20(USDC).approve(strataxProxy1, collateralAmount1);
        Stratax(strataxProxy1)
            .createLeveragedPosition(flashLoan1, collateralAmount1, borrow1, swap1, (expectedSwap1 * 97) / 100);
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

        (bytes memory swap2, uint256 expectedSwap2) = get1inchSwapData(USDC, WETH, borrow2, strataxProxy2);

        deal(WETH, trader, collateralAmount2);
        vm.startPrank(trader);
        IERC20(WETH).approve(strataxProxy2, collateralAmount2);
        Stratax(strataxProxy2)
            .createLeveragedPosition(flashLoan2, collateralAmount2, borrow2, swap2, (expectedSwap2 * 97) / 100);
        vm.stopPrank();

        // Verify both positions are active
        (uint256 collateral1, uint256 debt1,,,,) = IPool(AAVE_POOL).getUserAccountData(strataxProxy1);
        (uint256 collateral2, uint256 debt2,,,,) = IPool(AAVE_POOL).getUserAccountData(strataxProxy2);

        assertTrue(collateral1 > 0 && debt1 > 0, "Position 1 should be active");
        assertTrue(collateral2 > 0 && debt2 > 0, "Position 2 should be active");
    }

    function test_EmergencyWithdraw() public {
        uint256 strandedAmount = 100e6;
        deal(USDC, address(stratax), strandedAmount);

        vm.startPrank(ownerTrader);
        vm.expectRevert("Position must be burned to recover tokens");
        stratax.recoverTokens(USDC, strandedAmount);

        stratax.burnPosition(ownerTrader);

        uint256 ownerBefore = IERC20(USDC).balanceOf(ownerTrader);
        stratax.recoverTokens(USDC, strandedAmount);
        uint256 ownerAfter = IERC20(USDC).balanceOf(ownerTrader);
        vm.stopPrank();

        assertEq(ownerAfter, ownerBefore + strandedAmount, "Owner should recover stranded USDC after burn");
        assertEq(IERC20(USDC).balanceOf(address(stratax)), 0, "Stratax contract should have no stranded USDC left");
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
