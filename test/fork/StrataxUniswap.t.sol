// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Stratax_Aave_Uniswap as StrataxUniswap} from "../../src/core/position-types/Stratax_Aave_Uniswap.sol";
import {StrataxRouter} from "../../src/core/StrataxRouter.sol";
import {StrataxProtocolBeacon} from "../../src/core/StrataxProtocolBeacon.sol";
import {AaveUniswapPositionAdapter} from "../../src/core/adapters/AaveUniswapPositionAdapter.sol";
import {UniswapV3Executor} from "../../src/core/executors/UniswapV3Executor.sol";
import {StrataxAavePositionInitConstants} from "../../src/libraries/constants/StrataxAavePositionInitConstants.sol";
import {StrataxUniswapConstants} from "../../src/libraries/constants/StrataxUniswapConstants.sol";
import {StrataxUniswapLib} from "../../src/libraries/swapping/StrataxUniswapLib.sol";
import {IPool} from "../../src/interfaces/external/IPool.sol";
import {StrataxForkTestBase} from "./Base.t.sol";

contract StrataxUniswapForkTest is StrataxForkTestBase {
    bytes32 internal constant SWAP_UNISWAP_V3_ID = keccak256("SWAP:UNISWAP_V3");

    function test_MintAaveUniswapPosition() public {
        _configureDefaultAaveUniswap();

        address positionOwner = address(0xBEEF);
        (uint256 mintedTokenId, address strataxProxy) =
            strataxPositionNft.mintPosition(positionOwner, USDC, WETH, LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID);

        assertTrue(strataxProxy != address(0), "Stratax proxy should be deployed");
        assertEq(strataxPositionNft.ownerOf(mintedTokenId), positionOwner, "NFT owner should match mint recipient");
        _assertMintedUniswapPosition(mintedTokenId, strataxProxy);
    }

    function test_MintAndOpenUniswapPositionInOneCall() public {
        _configureDefaultAaveUniswap();

        StrataxRouter router = new StrataxRouter(address(strataxPositionNft));

        address positionOwner = address(0xCAFE);
        uint256 collateralAmount = 2000 * 10 ** 6; // 2000 USDC
        uint256 desiredLeverage = 25_000; // 2.5x
        uint24 poolFee = StrataxUniswapConstants.ETHEREUM_DEFAULT_UNISWAP_POOL_FEE;

        deal(USDC, positionOwner, collateralAmount);

        vm.startPrank(positionOwner);
        IERC20(USDC).approve(address(router), collateralAmount);

        address[] memory openPath = new address[](2);
        openPath[0] = WETH;
        openPath[1] = USDC;
        uint24[] memory openFees = new uint24[](1);
        openFees[0] = poolFee;

        (uint256 mintedTokenId, address strataxProxy) =
            router.createAaveUniswapPosition(USDC, WETH, collateralAmount, desiredLeverage, openPath, openFees, 0);
        vm.stopPrank();

        assertEq(strataxPositionNft.ownerOf(mintedTokenId), positionOwner, "NFT owner should match mint recipient");
        _assertMintedUniswapPosition(mintedTokenId, strataxProxy);

        (uint256 totalCollateral, uint256 totalDebt,,,, uint256 healthFactor) =
            IPool(AAVE_POOL).getUserAccountData(strataxProxy);

        assertTrue(totalCollateral > 0, "Position should have collateral after open");
        assertTrue(totalDebt > 0, "Position should have debt after open");
        assertTrue(healthFactor > 1e18, "Health factor should be above 1");
    }

    function _configureDefaultAaveUniswap() internal returns (AaveUniswapPositionAdapter adapter) {
        // Deploy dedicated implementation + beacon for the Aave+Uniswap protocol pair.
        StrataxUniswap uniswapImplementation = new StrataxUniswap();
        StrataxProtocolBeacon uniswapBeacon =
            new StrataxProtocolBeacon(address(uniswapImplementation), admin, LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID);

        vm.startPrank(admin);
        UniswapV3Executor uniswapExecutor = new UniswapV3Executor();
        adapter = new AaveUniswapPositionAdapter(address(strataxPositionNft), uniswapExecutor);
        strataxConfigManager.setProtocolPairConfig(
            LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID, address(uniswapBeacon), address(adapter)
        );

        bytes memory lendingData = abi.encode(
            StrataxAavePositionInitConstants.ethereumConfigParams(IPool(AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL())
        );
        bytes memory swapData = abi.encode(StrataxUniswapConstants.ethereumConfigParams());
        strataxConfigManager.setPlatformConfig(LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID, lendingData, swapData);
        vm.stopPrank();
    }

    function _assertMintedUniswapPosition(uint256 mintedTokenId, address strataxProxy) internal view {
        assertTrue(strataxProxy != address(0), "Stratax proxy should be deployed");

        (
            address collateralToken,
            address borrowToken,
            address positionProxy,
            bytes32 strategyId,
            bytes32 swapProtocolId,
            bytes32 lendingProtocolId,
            bool isActive,
            bool isBurned,
            uint256 createdAt
        ) = strataxPositionNft.positions(mintedTokenId);

        strategyId;
        createdAt;

        assertEq(collateralToken, USDC, "Collateral token should be USDC");
        assertEq(borrowToken, WETH, "Borrow token should be WETH");
        assertEq(positionProxy, strataxProxy, "Stored position proxy should match mint return value");
        assertEq(swapProtocolId, SWAP_UNISWAP_V3_ID, "Swap protocol id should be Uniswap V3");
        assertEq(lendingProtocolId, LENDING_AAVE_V3_ID, "Lending protocol id should be Aave V3");
        assertTrue(isActive, "Position should be active");
        assertTrue(!isBurned, "Position should not be burned");

        StrataxUniswap position = StrataxUniswap(strataxProxy);
        assertEq(address(position.uniswapRouter()), StrataxUniswapConstants.ETHEREUM_UNISWAP_V3_ROUTER);

        StrataxUniswapLib.Config memory swapConfig =
            abi.decode(strataxPositionNft.swapConfigByProtocolId(SWAP_UNISWAP_V3_ID), (StrataxUniswapLib.Config));
        assertEq(swapConfig.router, StrataxUniswapConstants.ETHEREUM_UNISWAP_V3_ROUTER);
        assertEq(swapConfig.quoter, StrataxUniswapConstants.ETHEREUM_UNISWAP_V3_QUOTER_V2);
        assertEq(swapConfig.poolFee, StrataxUniswapConstants.ETHEREUM_DEFAULT_UNISWAP_POOL_FEE);
    }

    // ── Path helpers ─────────────────────────────────────────────────────────

    /// @dev WETH → USDC: used when opening (borrow token → collateral token)
    function _openSwapPath() internal view returns (address[] memory path, uint24[] memory fees) {
        path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;
        fees = new uint24[](1);
        fees[0] = StrataxUniswapConstants.ETHEREUM_DEFAULT_UNISWAP_POOL_FEE;
    }

    /// @dev USDC → WETH: used when unwinding (collateral token → borrow token)
    function _unwindSwapPath() internal view returns (address[] memory path, uint24[] memory fees) {
        path = new address[](2);
        path[0] = USDC;
        path[1] = WETH;
        fees = new uint24[](1);
        fees[0] = StrataxUniswapConstants.ETHEREUM_DEFAULT_UNISWAP_POOL_FEE;
    }

    // ── Open helper ───────────────────────────────────────────────────────────

    function _openPositionViaRouter(address user, uint256 collateral, uint256 leverage)
        internal
        returns (uint256 tokenId_, address proxy_)
    {
        StrataxRouter router = new StrataxRouter(address(strataxPositionNft));

        deal(USDC, user, collateral);
        vm.startPrank(user);
        IERC20(USDC).approve(address(router), collateral);

        (address[] memory path, uint24[] memory fees) = _openSwapPath();
        (tokenId_, proxy_) = router.createAaveUniswapPosition(USDC, WETH, collateral, leverage, path, fees, 0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                   LEVERAGE — OPEN AT VARIOUS LEVELS
    //////////////////////////////////////////////////////////////*/

    function test_CreateLeveragedPosition_TwoX() public {
        _configureDefaultAaveUniswap();

        address user = makeAddr("user_2x");
        uint256 collateral = 2_000e6; // 2000 USDC
        uint256 targetLeverage = 20_000; // 2x (LEVERAGE_PRECISION = 10000)

        (, address proxy) = _openPositionViaRouter(user, collateral, targetLeverage);

        (uint256 totalCollateral, uint256 totalDebt,,,, uint256 healthFactor) =
            IPool(AAVE_POOL).getUserAccountData(proxy);

        assertTrue(totalCollateral > 0, "Should have collateral");
        assertTrue(totalDebt > 0, "Should have debt");
        assertTrue(healthFactor > 1e18, "Health factor should be above 1");

        uint256 currentLeverage = StrataxUniswap(proxy).getCurrentLeverage();
        assertApproxEqAbs(currentLeverage, targetLeverage, 500, "Leverage should be close to 2x");
    }

    function test_CreateLeveragedPosition_ThreeX() public {
        _configureDefaultAaveUniswap();

        address user = makeAddr("user_3x");
        uint256 collateral = 2_000e6;
        uint256 targetLeverage = 30_000; // 3x

        (, address proxy) = _openPositionViaRouter(user, collateral, targetLeverage);

        (,,,,, uint256 healthFactor) = IPool(AAVE_POOL).getUserAccountData(proxy);
        assertTrue(healthFactor > 1e18, "Health factor should be above 1");

        uint256 currentLeverage = StrataxUniswap(proxy).getCurrentLeverage();
        assertApproxEqAbs(currentLeverage, targetLeverage, 500, "Leverage should be close to 3x");
    }

    /*//////////////////////////////////////////////////////////////
               LEVERAGE ADJUSTMENT — INCREASE AND DECREASE
    //////////////////////////////////////////////////////////////*/

    function test_IncreaseLeverage_TwoXToThreeX() public {
        _configureDefaultAaveUniswap();

        address user = makeAddr("user_inc_lev");
        uint256 collateral = 2_000e6;

        (uint256 tokenId_, address proxy) = _openPositionViaRouter(user, collateral, 20_000);

        uint256 leverageBefore = StrataxUniswap(proxy).getCurrentLeverage();
        assertApproxEqAbs(leverageBefore, 20_000, 500, "Should start near 2x");

        // Check debt before
        (, uint256 totalDebtBefore,,,,) = IPool(AAVE_POOL).getUserAccountData(proxy);

        // User holds the NFT — adjust leverage directly on the position proxy
        (address[] memory path, uint24[] memory fees) = _openSwapPath();
        vm.prank(user);
        StrataxUniswap(proxy).adjustPositionLeverage(30_000, path, fees, 0);

        uint256 leverageAfter = StrataxUniswap(proxy).getCurrentLeverage();
        assertApproxEqAbs(leverageAfter, 30_000, 500, "Should end near 3x");

        (, uint256 totalDebtAfter,,,, uint256 healthFactor) = IPool(AAVE_POOL).getUserAccountData(proxy);
        assertTrue(totalDebtAfter > totalDebtBefore, "Debt should increase when leveraging up");
        assertTrue(healthFactor > 1e18, "Health factor must stay above 1");
    }

    function test_DecreaseLeverage_ThreeXToTwoX() public {
        _configureDefaultAaveUniswap();

        address user = makeAddr("user_dec_lev");
        uint256 collateral = 2_000e6;

        (uint256 tokenId_, address proxy) = _openPositionViaRouter(user, collateral, 30_000);

        uint256 leverageBefore = StrataxUniswap(proxy).getCurrentLeverage();
        assertApproxEqAbs(leverageBefore, 30_000, 500, "Should start near 3x");

        (, uint256 totalDebtBefore,,,,) = IPool(AAVE_POOL).getUserAccountData(proxy);

        (address[] memory path, uint24[] memory fees) = _unwindSwapPath();
        vm.prank(user);
        StrataxUniswap(proxy).adjustPositionLeverage(20_000, path, fees, 0);

        uint256 leverageAfter = StrataxUniswap(proxy).getCurrentLeverage();
        assertApproxEqAbs(leverageAfter, 20_000, 500, "Should end near 2x");

        (, uint256 totalDebtAfter,,,, uint256 healthFactor) = IPool(AAVE_POOL).getUserAccountData(proxy);
        assertTrue(totalDebtAfter < totalDebtBefore, "Debt should decrease when deleveraging");
        assertTrue(healthFactor > 1e18, "Health factor must stay above 1");
    }

    /*//////////////////////////////////////////////////////////////
                       UNWIND — PARTIAL AND FULL
    //////////////////////////////////////////////////////////////*/

    function test_UnwindPosition_Partial_ViaRouter() public {
        _configureDefaultAaveUniswap();

        address user = makeAddr("user_partial_unwind");
        uint256 collateral = 2_000e6;

        (uint256 tokenId_, address proxy) = _openPositionViaRouter(user, collateral, 25_000);

        // Read total debt in borrow-token units
        (, uint256 debtToRepayFull,) = StrataxUniswap(proxy).calculateUnwindParams(type(uint256).max);
        uint256 partialDebt = debtToRepayFull / 2;

        (, uint256 totalDebtBefore,,,,) = IPool(AAVE_POOL).getUserAccountData(proxy);

        StrataxRouter router = new StrataxRouter(address(strataxPositionNft));
        (address[] memory path, uint24[] memory fees) = _unwindSwapPath();

        vm.startPrank(user);
        strataxPositionNft.approve(address(router), tokenId_);
        router.unwindAaveUniswapPosition(tokenId_, partialDebt, path, fees, 0);
        vm.stopPrank();

        (, uint256 totalDebtAfter,,,, uint256 healthFactor) = IPool(AAVE_POOL).getUserAccountData(proxy);

        assertTrue(totalDebtAfter < totalDebtBefore, "Debt should decrease after partial unwind");
        assertTrue(totalDebtAfter > 0, "Position should still have debt after partial unwind");
        assertTrue(healthFactor > 1e18, "Health factor must stay above 1");
        assertEq(strataxPositionNft.ownerOf(tokenId_), user, "NFT must be returned to user");
    }

    function test_UnwindPosition_Full_ViaRouter() public {
        _configureDefaultAaveUniswap();

        address user = makeAddr("user_full_unwind");
        uint256 collateral = 2_000e6;

        (uint256 tokenId_, address proxy) = _openPositionViaRouter(user, collateral, 25_000);

        uint256 userUsdcBalanceBefore = IERC20(USDC).balanceOf(user);

        StrataxRouter router = new StrataxRouter(address(strataxPositionNft));
        (address[] memory path, uint24[] memory fees) = _unwindSwapPath();

        vm.startPrank(user);
        strataxPositionNft.approve(address(router), tokenId_);
        router.unwindAaveUniswapPosition(tokenId_, type(uint256).max, path, fees, 0);
        vm.stopPrank();

        (uint256 totalCollateralAfter, uint256 totalDebtAfter,,,,) = IPool(AAVE_POOL).getUserAccountData(proxy);

        // After full unwind debt should be cleared (may have dust)
        assertLt(totalDebtAfter, 1e8, "Debt should be fully repaid after full unwind");

        // USDC should not be returned directly to the user wallet after unwind.
        uint256 userUsdcBalanceAfter = IERC20(USDC).balanceOf(user);
        assertEq(userUsdcBalanceAfter, userUsdcBalanceBefore, "User should not receive immediate USDC on full unwind");

        // Collateral remains managed on the position (Aave account data), not as raw USDC in user wallet.
        assertTrue(totalCollateralAfter > 0, "Position should retain collateral after full unwind");

        assertEq(strataxPositionNft.ownerOf(tokenId_), user, "NFT must be returned to user");
    }

    function test_UnwindPosition_PartialThenFull_ViaRouter() public {
        _configureDefaultAaveUniswap();

        address user = makeAddr("user_two_step_unwind");
        uint256 collateral = 2_000e6;

        (uint256 tokenId_, address proxy) = _openPositionViaRouter(user, collateral, 25_000);

        StrataxRouter router = new StrataxRouter(address(strataxPositionNft));
        (address[] memory unwindPath, uint24[] memory unwindFees) = _unwindSwapPath();

        // ── Step 1: partial unwind ──
        (, uint256 fullDebt,) = StrataxUniswap(proxy).calculateUnwindParams(type(uint256).max);
        uint256 partialDebt = fullDebt / 3;

        vm.startPrank(user);
        strataxPositionNft.approve(address(router), tokenId_);
        router.unwindAaveUniswapPosition(tokenId_, partialDebt, unwindPath, unwindFees, 0);
        vm.stopPrank();

        (, uint256 debtAfterPartial,,,,) = IPool(AAVE_POOL).getUserAccountData(proxy);
        assertTrue(debtAfterPartial > 0, "Should still have debt after partial unwind");

        // ── Step 2: full unwind ──
        vm.startPrank(user);
        strataxPositionNft.approve(address(router), tokenId_);
        router.unwindAaveUniswapPosition(tokenId_, type(uint256).max, unwindPath, unwindFees, 0);
        vm.stopPrank();

        (, uint256 debtAfterFull,,,,) = IPool(AAVE_POOL).getUserAccountData(proxy);
        assertLt(debtAfterFull, 1e8, "Should have no debt after full unwind");
        assertEq(strataxPositionNft.ownerOf(tokenId_), user, "NFT must be returned to user");
    }

    /*//////////////////////////////////////////////////////////////
                        NEAR-MAX LEVERAGE
    //////////////////////////////////////////////////////////////*/

    function test_CreatePosition_AtNearMaxLeverage() public {
        _configureDefaultAaveUniswap();

        // Deploy minimal position to read the dynamic max leverage cap
        address scout = makeAddr("scout");
        (uint256 scoutTokenId, address scoutProxy) = _openPositionViaRouter(scout, 1_000e6, 20_000);

        // calculateOpenParams caps leverage at (LEVERAGE_PREC^2) / (LTV_PREC - ltv) - maxLeverageOffset.
        // We probe slightly below an optimistic upper bound; the contract will cap us at the real max.
        // For USDC on Aave V3 mainnet LTV ≥ 77%, theoretical max ≥ 43478, offset = 75 → safe cap ≥ 43403.
        // Using 38000 (3.8x) is well inside that bound for any realistically expected LTV.
        uint256 nearMaxLeverage = 38_000;

        address user = makeAddr("user_near_max");
        uint256 collateral = 2_000e6;

        (, address proxy) = _openPositionViaRouter(user, collateral, nearMaxLeverage);

        (uint256 totalCollateral, uint256 totalDebt,,,, uint256 healthFactor) =
            IPool(AAVE_POOL).getUserAccountData(proxy);

        assertTrue(totalCollateral > 0, "Should have collateral");
        assertTrue(totalDebt > 0, "Should have debt");
        assertTrue(healthFactor > 1e18, "Health factor must be above 1 even at near-max leverage");

        uint256 currentLeverage = StrataxUniswap(proxy).getCurrentLeverage();
        assertGt(currentLeverage, 35_000, "Leverage should be high (>3.5x)");
    }

    function test_HealthFactor_SafeAtNearMaxLeverage() public {
        _configureDefaultAaveUniswap();

        address user = makeAddr("user_hf_near_max");
        uint256 collateral = 5_000e6; // bigger position for precision

        (, address proxy) = _openPositionViaRouter(user, collateral, 38_000);

        (,,,,, uint256 healthFactor) = IPool(AAVE_POOL).getUserAccountData(proxy);

        // Even at near-max leverage the position must stay above liquidation threshold.
        // The protocol enforces a borrow safety margin so HF > 1 should always hold.
        assertTrue(healthFactor > 1e18, "Health factor must be above 1");
        // And should not be absurdly high either — confirm real leverage was applied
        assertLt(healthFactor, 20e18, "Health factor should reflect high-leverage position");
    }

    function test_NearMaxLeverage_ThenIncreaseFails() public {
        _configureDefaultAaveUniswap();

        address user = makeAddr("user_max_then_fail");
        uint256 collateral = 2_000e6;

        (uint256 tokenId_, address proxy) = _openPositionViaRouter(user, collateral, 38_000);

        // Attempt to push beyond the actual max; position should revert
        (address[] memory path, uint24[] memory fees) = _openSwapPath();
        vm.prank(user);
        vm.expectRevert();
        StrataxUniswap(proxy).adjustPositionLeverage(60_000, path, fees, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    OPEN AT CONTRACT-REPORTED MAX LEVERAGE
    //////////////////////////////////////////////////////////////*/

    function test_CreatePosition_AtContractMaxLeverage() public {
        _configureDefaultAaveUniswap();

        address user = makeAddr("user_contract_max");
        uint256 collateral = 2_000e6;

        // Open a seed position so getMaxLeverage() can query Aave's LTV on-chain.
        (, address proxy) = _openPositionViaRouter(user, collateral, 20_000);

        uint256 maxLeverage = StrataxUniswap(proxy).getMaxLeverage();
        assertTrue(maxLeverage > StrataxUniswap(proxy).getCurrentLeverage(), "Max leverage should be above current");
        assertTrue(maxLeverage > 0, "Max leverage must be non-zero");

        // Open a fresh position at exactly the reported max leverage.
        address user2 = makeAddr("user_at_max");
        (, address proxy2) = _openPositionViaRouter(user2, collateral, maxLeverage);

        (uint256 totalCollateral, uint256 totalDebt,,,, uint256 healthFactor) =
            IPool(AAVE_POOL).getUserAccountData(proxy2);

        assertTrue(totalCollateral > 0, "Should have collateral");
        assertTrue(totalDebt > 0, "Should have debt");
        assertTrue(healthFactor > 1e18, "Health factor must stay above 1 at max leverage");

        uint256 achievedLeverage = StrataxUniswap(proxy2).getCurrentLeverage();
        // Achieved leverage should be very close to the reported max (within 1% given slippage/rounding).
        assertApproxEqRel(achievedLeverage, maxLeverage, 0.01e18, "Achieved leverage should match max");
    }

    function test_CreatePosition_AboveMaxLeverageReverts() public {
        _configureDefaultAaveUniswap();

        address user = makeAddr("user_above_max");
        uint256 collateral = 2_000e6;

        // Open a seed position to read the on-chain max.
        (, address proxy) = _openPositionViaRouter(user, collateral, 20_000);
        uint256 maxLeverage = StrataxUniswap(proxy).getMaxLeverage();

        // Requesting even one unit above the max must revert.
        address user2 = makeAddr("user_above_max_2");
        deal(USDC, user2, collateral);
        StrataxRouter router = new StrataxRouter(address(strataxPositionNft));

        vm.startPrank(user2);
        IERC20(USDC).approve(address(router), collateral);

        (address[] memory path, uint24[] memory fees) = _openSwapPath();
        vm.expectRevert();
        router.createAaveUniswapPosition(USDC, WETH, collateral, maxLeverage + 1, path, fees, 0);
        vm.stopPrank();
    }
}
