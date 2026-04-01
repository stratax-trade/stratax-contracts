// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {console} from "forge-std/Test.sol";
import {StrataxRouter} from "../../src/core/StrataxRouter.sol";
import {Stratax_Aave_Uniswap as StrataxUniswap} from "../../src/core/position-types/Stratax_Aave_Uniswap.sol";
import {Stratax_Aave_1Inch as Stratax} from "../../src/core/position-types/Stratax_Aave_1Inch.sol";
import {StrataxProtocolBeacon} from "../../src/core/StrataxProtocolBeacon.sol";
import {AaveUniswapPositionAdapter} from "../../src/core/adapters/AaveUniswapPositionAdapter.sol";
import {StrataxAavePositionInitConstants} from "../../src/libraries/constants/StrataxAavePositionInitConstants.sol";
import {StrataxUniswapConstants} from "../../src/libraries/constants/StrataxUniswapConstants.sol";
import {IPool} from "../../src/interfaces/external/IPool.sol";
import {IStrataxPositionAdapter} from "../../src/interfaces/internal/IStrataxPositionAdapter.sol";
import {StrataxForkTestBase} from "./Base.t.sol";

contract StrataxRouterForkTest is StrataxForkTestBase {
    bytes32 internal constant SWAP_UNISWAP_V3_ID = keccak256("SWAP:UNISWAP_V3");

    StrataxRouter public router;

    function setUp() public override {
        super.setUp();

        // Deploy the router
        router = new StrataxRouter(address(strataxPositionNft));

        // Configure Uniswap protocol pair (Aave + Uniswap)
        _configureUniswapProtocol();
    }

    /*//////////////////////////////////////////////////////////////
                    UNISWAP — MINT ONLY
    //////////////////////////////////////////////////////////////*/

    function test_Router_MintPosition_Uniswap() public {
        address user = address(0xBEEF);

        vm.prank(user);
        (uint256 tokenId, address strataxProxy) =
            router.mintPosition(USDC, WETH, LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID);

        assertTrue(strataxProxy != address(0), "Stratax proxy should be deployed");
        assertEq(strataxPositionNft.ownerOf(tokenId), user, "NFT owner should be user");
    }

    /*//////////////////////////////////////////////////////////////
                    UNISWAP — MINT + OPEN
    //////////////////////////////////////////////////////////////*/

    function test_Router_CreateUniswapPosition() public {
        address user = address(0xCAFE);
        uint256 collateralAmount = 2000 * 10 ** 6; // 2000 USDC
        uint256 desiredLeverage = 25_000; // 2.5x
        uint24 poolFee = StrataxUniswapConstants.ETHEREUM_DEFAULT_UNISWAP_POOL_FEE;

        deal(USDC, user, collateralAmount);

        vm.startPrank(user);
        IERC20(USDC).approve(address(router), collateralAmount);

        address[] memory openPath = new address[](2);
        openPath[0] = WETH;
        openPath[1] = USDC;
        uint24[] memory openFees = new uint24[](1);
        openFees[0] = poolFee;

        (uint256 tokenId, address strataxProxy) =
            router.createAaveUniswapPosition(USDC, WETH, collateralAmount, desiredLeverage, openPath, openFees, 0);
        vm.stopPrank();

        // Verify NFT ownership
        assertEq(strataxPositionNft.ownerOf(tokenId), user, "NFT owner should be user");

        // Verify position was opened with collateral and debt
        (uint256 totalCollateral, uint256 totalDebt,,,, uint256 healthFactor) =
            IPool(AAVE_POOL).getUserAccountData(strataxProxy);

        assertTrue(totalCollateral > 0, "Position should have collateral");
        assertTrue(totalDebt > 0, "Position should have debt");
        assertTrue(healthFactor > 1e18, "Health factor should be above 1");
    }

    /*//////////////////////////////////////////////////////////////
                    UNISWAP — UNWIND VIA ROUTER
    //////////////////////////////////////////////////////////////*/

    function test_Router_UnwindUniswapPosition_Partial() public {
        // Create position first
        address user = address(0xCAFE);
        uint256 collateralAmount = 2000 * 10 ** 6;
        uint256 desiredLeverage = 20_000; // 2x
        uint24 poolFee = StrataxUniswapConstants.ETHEREUM_DEFAULT_UNISWAP_POOL_FEE;

        deal(USDC, user, collateralAmount);

        vm.startPrank(user);
        IERC20(USDC).approve(address(router), collateralAmount);
        address[] memory openPath = new address[](2);
        openPath[0] = WETH;
        openPath[1] = USDC;
        uint24[] memory fees = new uint24[](1);
        fees[0] = poolFee;
        (uint256 tokenId,) =
            router.createAaveUniswapPosition(USDC, WETH, collateralAmount, desiredLeverage, openPath, fees, 0);

        address strataxProxy = strataxPositionNft.getStrataxProxy(tokenId);
        (, uint256 totalDebtBefore,,,,) = IPool(AAVE_POOL).getUserAccountData(strataxProxy);

        // Get actual WETH debt in token units (not the USD-denominated value from getUserAccountData)
        (, uint256 totalDebtInWeth,) = StrataxUniswap(strataxProxy).calculateUnwindParams(type(uint256).max);

        // Approve router for NFT to perform unwind
        strataxPositionNft.approve(address(router), tokenId);

        // Partial unwind — repay half the debt (in borrow token units)
        uint256 partialDebt = totalDebtInWeth / 2;
        address[] memory unwindPath = new address[](2);
        unwindPath[0] = USDC;
        unwindPath[1] = WETH;
        router.unwindAaveUniswapPosition(tokenId, partialDebt, unwindPath, fees, 0);
        vm.stopPrank();

        // Verify debt was reduced
        (, uint256 totalDebtAfter,,,,) = IPool(AAVE_POOL).getUserAccountData(strataxProxy);
        assertTrue(totalDebtAfter < totalDebtBefore, "Debt should be reduced");
        assertTrue(totalDebtAfter > 0, "Position should still have debt");

        // Verify NFT returned to user
        assertEq(strataxPositionNft.ownerOf(tokenId), user, "NFT should be returned to user");
    }

    function test_Router_UnwindUniswapPosition_Full() public {
        address user = address(0xCAFE);
        uint256 collateralAmount = 2000 * 10 ** 6;
        uint256 desiredLeverage = 20_000;
        uint24 poolFee = StrataxUniswapConstants.ETHEREUM_DEFAULT_UNISWAP_POOL_FEE;

        deal(USDC, user, collateralAmount);

        vm.startPrank(user);
        IERC20(USDC).approve(address(router), collateralAmount);
        address[] memory openPath = new address[](2);
        openPath[0] = WETH;
        openPath[1] = USDC;
        uint24[] memory fees = new uint24[](1);
        fees[0] = poolFee;
        (uint256 tokenId,) =
            router.createAaveUniswapPosition(USDC, WETH, collateralAmount, desiredLeverage, openPath, fees, 0);

        // Approve router for NFT
        strataxPositionNft.approve(address(router), tokenId);

        // Full unwind
        address[] memory unwindPath = new address[](2);
        unwindPath[0] = USDC;
        unwindPath[1] = WETH;
        router.unwindAaveUniswapPosition(tokenId, type(uint256).max, unwindPath, fees, 0);
        vm.stopPrank();

        // Verify position fully unwound
        address strataxProxy = strataxPositionNft.getStrataxProxy(tokenId);
        (, uint256 totalDebt,,,,) = IPool(AAVE_POOL).getUserAccountData(strataxProxy);
        assertEq(totalDebt, 0, "Debt should be zero after full unwind");

        // NFT should be returned
        assertEq(strataxPositionNft.ownerOf(tokenId), user, "NFT should be returned to user");
    }

    /*//////////////////////////////////////////////////////////////
                    COLLATERAL & DEBT MANAGEMENT VIA ROUTER
    //////////////////////////////////////////////////////////////*/

    function test_Router_SupplyCollateral() public {
        // Create position with no leverage first
        address user = address(0xCAFE);

        vm.prank(user);
        (uint256 tokenId, address strataxProxy) =
            router.mintPosition(USDC, WETH, LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID);

        uint256 supplyAmount = 1000 * 10 ** 6;
        deal(USDC, user, supplyAmount);

        vm.startPrank(user);
        IERC20(USDC).approve(address(router), supplyAmount);
        strataxPositionNft.approve(address(router), tokenId);

        router.supplyCollateral(tokenId, supplyAmount);
        vm.stopPrank();

        // Verify collateral was supplied
        (uint256 totalCollateral,,,,,) = IPool(AAVE_POOL).getUserAccountData(strataxProxy);
        assertTrue(totalCollateral > 0, "Position should have collateral");

        // NFT should be returned
        assertEq(strataxPositionNft.ownerOf(tokenId), user, "NFT should be returned to user");
    }

    function test_Router_BorrowDebtToken() public {
        // Create and supply collateral first
        address user = address(0xCAFE);
        uint256 collateralAmount = 2000 * 10 ** 6;
        uint24 poolFee = StrataxUniswapConstants.ETHEREUM_DEFAULT_UNISWAP_POOL_FEE;

        deal(USDC, user, collateralAmount);

        vm.startPrank(user);
        IERC20(USDC).approve(address(router), collateralAmount);
        address[] memory openPath = new address[](2);
        openPath[0] = WETH;
        openPath[1] = USDC;
        uint24[] memory fees = new uint24[](1);
        fees[0] = poolFee;
        (uint256 tokenId, address strataxProxy) =
            router.createAaveUniswapPosition(USDC, WETH, collateralAmount, 15_000, openPath, fees, 0);

        // Borrow more via router
        uint256 borrowAmount = 0.1 ether;
        strataxPositionNft.approve(address(router), tokenId);
        router.borrowDebtToken(tokenId, borrowAmount);
        vm.stopPrank();

        // User should have received the borrowed tokens
        assertTrue(IERC20(WETH).balanceOf(user) >= borrowAmount, "User should have borrowed tokens");

        // NFT should be returned
        assertEq(strataxPositionNft.ownerOf(tokenId), user, "NFT should be returned to user");
    }

    function test_Router_RepayDebtToken() public {
        address user = address(0xCAFE);
        uint256 collateralAmount = 2000 * 10 ** 6;
        uint24 poolFee = StrataxUniswapConstants.ETHEREUM_DEFAULT_UNISWAP_POOL_FEE;

        deal(USDC, user, collateralAmount);

        vm.startPrank(user);
        IERC20(USDC).approve(address(router), collateralAmount);
        address[] memory openPath = new address[](2);
        openPath[0] = WETH;
        openPath[1] = USDC;
        uint24[] memory fees = new uint24[](1);
        fees[0] = poolFee;
        (uint256 tokenId, address strataxProxy) =
            router.createAaveUniswapPosition(USDC, WETH, collateralAmount, 20_000, openPath, fees, 0);

        (, uint256 debtBefore,,,,) = IPool(AAVE_POOL).getUserAccountData(strataxProxy);

        // Repay some debt via router
        uint256 repayAmount = 0.1 ether;
        deal(WETH, user, repayAmount);
        IERC20(WETH).approve(address(router), repayAmount);
        strataxPositionNft.approve(address(router), tokenId);
        router.repayDebtToken(tokenId, repayAmount);
        vm.stopPrank();

        (, uint256 debtAfter,,,,) = IPool(AAVE_POOL).getUserAccountData(strataxProxy);
        assertTrue(debtAfter < debtBefore, "Debt should decrease after repayment");

        // NFT should be returned
        assertEq(strataxPositionNft.ownerOf(tokenId), user, "NFT should be returned to user");
    }

    /*//////////////////////////////////////////////////////////////
                    1INCH — MINT + OPEN VIA ROUTER
    //////////////////////////////////////////////////////////////*/

    function test_Router_CreateOneInchPosition() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        address user = address(0xBBBB);
        uint256 collateralAmount = 1000 * 10 ** 6;
        uint256 desiredLeverage = 25_000;

        // Step 1: Calculate open params using the existing stratax position (from base setUp)
        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: desiredLeverage,
                collateralAmount: collateralAmount,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
            })
        );

        // Step 2: Predict the proxy address for 1inch swap data
        // For 1inch, we need the predicted proxy address to get accurate swap data.
        // In a real integration, the user would use router.predictNextProxyAddress().
        address adapterAddr = strataxPositionNft.pairAdapterByProtocolIds(LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID);
        bytes memory lendingConfigData = strataxPositionNft.lendingConfigByProtocolId(LENDING_AAVE_V3_ID);
        bytes memory swapConfigData = strataxPositionNft.swapConfigByProtocolId(SWAP_ONEINCH_V6_ID);
        uint256 nextTokenId = strataxPositionNft.getTotalPositionsCreated() + 1;
        (address beacon,) = strataxPositionNft.protocolPairConfig(LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID);

        bytes memory strataxInitConfig = abi.encode(
            beacon,
            address(strataxPositionNft),
            nextTokenId,
            strataxPositionNft.strataxOracle(),
            strataxPositionNft.feeCollector(),
            USDC,
            WETH
        );
        // The router is the caller to positionNft, so use the router's salt
        bytes32 deploymentSalt = strataxPositionNft.getEffectiveCallerCreate2Salt(address(router));
        address predictedProxy = IStrataxPositionAdapter(adapterAddr)
            .predictDeploymentAddress(lendingConfigData, swapConfigData, strataxInitConfig, deploymentSalt);

        // Pre-fund so 1inch API can see balances
        deal(WETH, predictedProxy, borrowAmount);

        // Step 3: Get 1inch swap data
        (bytes memory swapData,) = get1inchSwapData(WETH, USDC, borrowAmount, predictedProxy);

        // Step 4: Create position via router
        deal(USDC, user, collateralAmount);

        vm.startPrank(user);
        IERC20(USDC).approve(address(router), collateralAmount);

        (uint256 tokenId, address strataxProxy) =
            router.createAaveOneInchPosition(USDC, WETH, collateralAmount, flashLoanAmount, borrowAmount, swapData, 0);
        vm.stopPrank();

        // Verify
        assertEq(strataxPositionNft.ownerOf(tokenId), user, "NFT owner should be user");

        (uint256 totalCollateral, uint256 totalDebt,,,, uint256 healthFactor) =
            IPool(AAVE_POOL).getUserAccountData(strataxProxy);

        assertTrue(totalCollateral > 0, "Position should have collateral");
        assertTrue(totalDebt > 0, "Position should have debt");
        assertTrue(healthFactor > 1e18, "Health factor should be above 1");
    }

    /*//////////////////////////////////////////////////////////////
                    1INCH — UNWIND VIA ROUTER
    //////////////////////////////////////////////////////////////*/

    function test_Router_UnwindOneInchPosition() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        // Open a 1inch position via the base setUp's stratax instance
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
        stratax.createLeveragedPosition(flashLoanAmount, collateralAmount, borrowAmount, openSwapData, 0);

        (, uint256 totalDebtBefore,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));

        // Calculate unwind params
        (uint256 collateralToWithdraw, uint256 debtAmount,) = stratax.calculateUnwindParams(type(uint256).max);
        collateralToWithdraw = (collateralToWithdraw * 103) / 100;

        // Get 1inch swap data for unwind
        (bytes memory unwindSwapData,) = get1inchSwapData(USDC, WETH, collateralToWithdraw, address(stratax));

        // Approve router for NFT and unwind
        strataxPositionNft.approve(address(router), tokenId);
        router.unwindAaveOneInchPosition(tokenId, collateralToWithdraw, debtAmount, unwindSwapData, 0);
        vm.stopPrank();

        // Verify
        (, uint256 totalDebtAfter,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));
        assertTrue(totalDebtAfter < totalDebtBefore, "Debt should be reduced");

        // NFT returned to owner
        assertEq(strataxPositionNft.ownerOf(tokenId), ownerTrader, "NFT should be returned");
    }

    /*//////////////////////////////////////////////////////////////
                    VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Router_PredictNextProxyAddress() public view {
        address predicted = router.predictNextProxyAddress(USDC, WETH, LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID);
        assertTrue(predicted != address(0), "Predicted address should be non-zero");
    }

    /*//////////////////////////////////////////////////////////////
                    ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Router_RevertIfNotOwner_Unwind() public {
        address user = address(0xCAFE);
        uint24 poolFee = StrataxUniswapConstants.ETHEREUM_DEFAULT_UNISWAP_POOL_FEE;
        uint256 collateralAmount = 2000 * 10 ** 6;

        deal(USDC, user, collateralAmount);

        vm.startPrank(user);
        IERC20(USDC).approve(address(router), collateralAmount);
        address[] memory openPath = new address[](2);
        openPath[0] = WETH;
        openPath[1] = USDC;
        uint24[] memory fees = new uint24[](1);
        fees[0] = poolFee;
        (uint256 tokenId,) = router.createAaveUniswapPosition(USDC, WETH, collateralAmount, 20_000, openPath, fees, 0);
        vm.stopPrank();

        // Different user tries to unwind
        address attacker = address(0xDEAD);
        vm.prank(attacker);
        vm.expectRevert(StrataxRouter.NotPositionOwner.selector);
        address[] memory unwindPath = new address[](2);
        unwindPath[0] = USDC;
        unwindPath[1] = WETH;
        router.unwindAaveUniswapPosition(tokenId, type(uint256).max, unwindPath, fees, 0);
    }

    function test_Router_RevertIfWrongSwapProtocol() public {
        // Mint a 1inch position (from base setUp)
        // Try to unwind it as Uniswap
        vm.startPrank(ownerTrader);
        strataxPositionNft.approve(address(router), tokenId);

        vm.expectRevert(StrataxRouter.InvalidSwapProtocol.selector);
        address[] memory dummyPath = new address[](2);
        dummyPath[0] = USDC;
        dummyPath[1] = WETH;
        uint24[] memory dummyFees = new uint24[](1);
        dummyFees[0] = StrataxUniswapConstants.ETHEREUM_DEFAULT_UNISWAP_POOL_FEE;
        router.unwindAaveUniswapPosition(tokenId, type(uint256).max, dummyPath, dummyFees, 0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _configureUniswapProtocol() internal {
        StrataxUniswap uniswapImplementation = new StrataxUniswap();
        StrataxProtocolBeacon uniswapBeacon =
            new StrataxProtocolBeacon(address(uniswapImplementation), admin, LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID);

        vm.startPrank(admin);
        AaveUniswapPositionAdapter adapter = new AaveUniswapPositionAdapter(address(strataxPositionNft));
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
}
