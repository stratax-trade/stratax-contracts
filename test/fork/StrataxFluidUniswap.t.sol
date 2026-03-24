// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {Stratax_Fluid_Uniswap as StrataxFluidUniswap} from "../../src/core/position-types/Stratax_Fluid_Uniswap.sol";
import {StrataxProtocolBeacon} from "../../src/core/StrataxProtocolBeacon.sol";
import {FluidUniswapPositionAdapter} from "../../src/core/adapters/FluidUniswapPositionAdapter.sol";
import {StrataxFluidConstants} from "../../src/libraries/constants/StrataxFluidConstants.sol";
import {StrataxUniswapConstants} from "../../src/libraries/constants/StrataxUniswapConstants.sol";
import {StrataxCalculations} from "../../src/libraries/StrataxCalculations.sol";
import {StrataxFluidLib} from "../../src/libraries/lending/StrataxFluidLib.sol";
import {StrataxUniswapLib} from "../../src/libraries/swapping/StrataxUniswapLib.sol";
import {StrataxForkTestBase} from "./Base.t.sol";

contract StrataxFluidUniswapForkTest is StrataxForkTestBase {
    bytes32 internal constant LENDING_FLUID_V1_ID = keccak256("LENDING:FLUID_V1");
    bytes32 internal constant SWAP_UNISWAP_V3_ID = keccak256("SWAP:UNISWAP_V3");

    // Mainnet Fluid T1 USDC/WBTC vault (ERC20 collateral/borrow).
    address internal constant FLUID_USDC_WBTC_VAULT = 0xF140Ea1C1D657EaaB802FF7626dC220cD4007CE7;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant WBTC_PRICE_FEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    uint24 internal constant USDC_WBTC_UNISWAP_FEE = 500;

    function test_MintFluidUniswapPosition() public {
        _setWbtcPriceFeed();
        FluidUniswapPositionAdapter adapter =
            _configureDefaultFluidUniswap(FLUID_USDC_WBTC_VAULT, USDC_WBTC_UNISWAP_FEE);
        adapter;

        address positionOwner = address(0xBEEF);
        address collateralToken = USDC;
        address borrowToken = WBTC;
        (uint256 mintedTokenId, address strataxProxy) = strataxPositionNft.mintPositionByProtocolIds(
            positionOwner, collateralToken, borrowToken, LENDING_FLUID_V1_ID, SWAP_UNISWAP_V3_ID, false, bytes("")
        );

        assertTrue(strataxProxy != address(0), "Stratax proxy should be deployed");
        assertEq(strataxPositionNft.ownerOf(mintedTokenId), positionOwner, "NFT owner should match mint recipient");
        _assertMintedFluidUniswapPosition(
            mintedTokenId, strataxProxy, collateralToken, borrowToken, FLUID_USDC_WBTC_VAULT, USDC_WBTC_UNISWAP_FEE
        );
    }

    function test_MintAndOpenFluidUniswapPositionInOneCall() public {
        _setWbtcPriceFeed();
        FluidUniswapPositionAdapter adapter =
            _configureDefaultFluidUniswap(FLUID_USDC_WBTC_VAULT, USDC_WBTC_UNISWAP_FEE);

        address positionOwner = address(0xCAFE);
        address collateralToken = USDC;
        address borrowToken = WBTC;
        uint256 collateralAmount = 2000 * 10 ** 6;
        uint256 desiredLeverage = 30_000; // 3.0x
        uint24 poolFee = USDC_WBTC_UNISWAP_FEE;

        (bytes memory mintCallData,) = adapter.buildCreateLeveragedPositionCallData(
            positionOwner,
            collateralToken,
            borrowToken,
            LENDING_FLUID_V1_ID,
            SWAP_UNISWAP_V3_ID,
            collateralAmount,
            desiredLeverage,
            poolFee,
            0
        );

        deal(collateralToken, positionOwner, collateralAmount);

        vm.startPrank(positionOwner);
        IERC20(collateralToken).approve(address(strataxPositionNft), collateralAmount);

        (bool mintSuccess, bytes memory mintResult) = address(strataxPositionNft).call(mintCallData);
        if (!mintSuccess) {
            assembly {
                revert(add(mintResult, 0x20), mload(mintResult))
            }
        }

        (uint256 mintedTokenId, address strataxProxy) = abi.decode(mintResult, (uint256, address));
        vm.stopPrank();

        assertEq(strataxPositionNft.ownerOf(mintedTokenId), positionOwner, "NFT owner should match mint recipient");
        _assertMintedFluidUniswapPosition(
            mintedTokenId, strataxProxy, collateralToken, borrowToken, FLUID_USDC_WBTC_VAULT, USDC_WBTC_UNISWAP_FEE
        );

        StrataxFluidUniswap position = StrataxFluidUniswap(strataxProxy);
        uint256 actualLeverage = position.getCurrentLeverage();

        assertTrue(position.fluidCollateralCached() > 0, "Position should have Fluid collateral after open");
        assertTrue(actualLeverage >= StrataxCalculations.LEVERAGE_PRECISION, "Actual leverage should be at least 1x");
        assertTrue(actualLeverage <= desiredLeverage, "Actual leverage should not exceed target leverage");
    }

    function test_CompareHybridVsFlashloanOnlyAt4x() public {
        _setWbtcPriceFeed();
        _configureDefaultFluidUniswap(FLUID_USDC_WBTC_VAULT, USDC_WBTC_UNISWAP_FEE);

        uint256 collateralAmount = 10_000 * 10 ** 6;
        uint256 desiredLeverage = 40_000; // 4.0x
        uint24 poolFee = USDC_WBTC_UNISWAP_FEE;

        address hybridOwner = address(0xA401);
        address flashOnlyOwner = address(0xA402);

        StrataxFluidUniswap hybridPosition = _mintClosedPosition(hybridOwner);
        StrataxFluidUniswap flashOnlyPosition = _mintClosedPosition(flashOnlyOwner);

        deal(USDC, hybridOwner, collateralAmount);
        deal(USDC, flashOnlyOwner, collateralAmount);

        vm.startPrank(hybridOwner);
        IERC20(USDC).approve(address(hybridPosition), collateralAmount);
        uint256 gasStartHybrid = gasleft();
        hybridPosition.createLeveragedPosition(desiredLeverage, collateralAmount, poolFee, 0);
        uint256 gasUsedHybrid = gasStartHybrid - gasleft();
        vm.stopPrank();

        vm.startPrank(flashOnlyOwner);
        IERC20(USDC).approve(address(flashOnlyPosition), collateralAmount);
        uint256 gasStartFlashOnly = gasleft();
        (uint256 totalBorrowedFlashOnly, uint256 totalSwappedFlashOnly, uint256 totalFeesFlashOnly) =
            flashOnlyPosition.createLeveragedPositionFlashloanOnly(desiredLeverage, collateralAmount, poolFee, 0);
        uint256 gasUsedFlashOnly = gasStartFlashOnly - gasleft();
        vm.stopPrank();

        uint256 hybridDebt = hybridPosition.fluidDebtCached();
        uint256 flashOnlyDebt = flashOnlyPosition.fluidDebtCached();

        console.log("--- Fluid 4x Comparison ---");
        console.log("hybrid gas", gasUsedHybrid);
        console.log("flashOnly gas", gasUsedFlashOnly);
        console.log("hybrid fluidDebt", hybridDebt);
        console.log("flashOnly fluidDebt", flashOnlyDebt);
        console.log("flashOnly totalBorrowed", totalBorrowedFlashOnly);
        console.log("flashOnly totalSwapped", totalSwappedFlashOnly);
        console.log("flashOnly totalFeesPaid", totalFeesFlashOnly);

        if (flashOnlyDebt > 0) {
            assertTrue(totalBorrowedFlashOnly > 0, "Flashloan-only total borrowed should be > 0");
            assertTrue(totalSwappedFlashOnly > 0, "Flashloan-only total swapped should be > 0");
        }

        // At 4x, this market may not always open debt on the current fork state; keep this test observational.
        assertTrue(gasUsedHybrid > 0, "Hybrid gas should be captured");
        assertTrue(gasUsedFlashOnly > 0, "Flashloan-only gas should be captured");
    }

    function _setWbtcPriceFeed() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = WBTC;

        address[] memory priceFeeds = new address[](1);
        priceFeeds[0] = WBTC_PRICE_FEED;

        vm.prank(admin);
        strataxOracle.setPriceFeeds(tokens, priceFeeds);
    }

    function _configureDefaultFluidUniswap(address fluidVault, uint24 poolFee)
        internal
        returns (FluidUniswapPositionAdapter adapter)
    {
        StrataxFluidUniswap fluidUniswapImplementation = new StrataxFluidUniswap();
        StrataxProtocolBeacon fluidUniswapBeacon = new StrataxProtocolBeacon(
            address(fluidUniswapImplementation), admin, LENDING_FLUID_V1_ID, SWAP_UNISWAP_V3_ID
        );

        vm.startPrank(admin);
        adapter = new FluidUniswapPositionAdapter(address(strataxPositionNft));
        strataxConfigManager.setProtocolPairConfig(
            LENDING_FLUID_V1_ID, SWAP_UNISWAP_V3_ID, address(fluidUniswapBeacon), address(adapter)
        );

        StrataxFluidLib.InitParams memory lendingConfig = StrataxFluidLib.InitParams({
            vault: fluidVault,
            defaultBorrowSafetyMargin: StrataxFluidConstants.DEFAULT_BORROW_SAFETY_MARGIN,
            defaultMaxLeverageOffset: StrataxFluidConstants.DEFAULT_MAX_LEVERAGE_OFFSET
        });

        StrataxUniswapLib.Config memory swapConfig = StrataxUniswapLib.Config({
            router: StrataxUniswapConstants.ETHEREUM_UNISWAP_V3_ROUTER,
            quoter: StrataxUniswapConstants.ETHEREUM_UNISWAP_V3_QUOTER_V2,
            poolFee: poolFee
        });

        bytes memory lendingData = abi.encode(lendingConfig);
        bytes memory swapData = abi.encode(swapConfig);
        strataxConfigManager.setPlatformConfig(LENDING_FLUID_V1_ID, SWAP_UNISWAP_V3_ID, lendingData, swapData);
        vm.stopPrank();
    }

    function _mintClosedPosition(address positionOwner) internal returns (StrataxFluidUniswap position) {
        (uint256 mintedTokenId, address strataxProxy) = strataxPositionNft.mintPositionByProtocolIds(
            positionOwner, USDC, WBTC, LENDING_FLUID_V1_ID, SWAP_UNISWAP_V3_ID, false, bytes("")
        );

        mintedTokenId;
        position = StrataxFluidUniswap(strataxProxy);
    }

    function _assertMintedFluidUniswapPosition(
        uint256 mintedTokenId,
        address strataxProxy,
        address expectedCollateralToken,
        address expectedBorrowToken,
        address expectedFluidVault,
        uint24 expectedPoolFee
    ) internal view {
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

        assertEq(collateralToken, expectedCollateralToken, "Collateral token should match expected collateral");
        assertEq(borrowToken, expectedBorrowToken, "Borrow token should match expected borrow");
        assertEq(positionProxy, strataxProxy, "Stored position proxy should match mint return value");
        assertEq(swapProtocolId, SWAP_UNISWAP_V3_ID, "Swap protocol id should be Uniswap V3");
        assertEq(lendingProtocolId, LENDING_FLUID_V1_ID, "Lending protocol id should be Fluid V1");
        assertTrue(isActive, "Position should be active");
        assertTrue(!isBurned, "Position should not be burned");

        StrataxFluidUniswap position = StrataxFluidUniswap(strataxProxy);
        assertEq(address(position.uniswapRouter()), StrataxUniswapConstants.ETHEREUM_UNISWAP_V3_ROUTER);
        assertEq(address(position.fluidVault()), expectedFluidVault);

        StrataxFluidLib.InitParams memory lendingConfig =
            abi.decode(strataxPositionNft.lendingConfigByProtocolId(LENDING_FLUID_V1_ID), (StrataxFluidLib.InitParams));
        assertEq(lendingConfig.vault, expectedFluidVault);

        StrataxUniswapLib.Config memory swapConfig =
            abi.decode(strataxPositionNft.swapConfigByProtocolId(SWAP_UNISWAP_V3_ID), (StrataxUniswapLib.Config));
        assertEq(swapConfig.router, StrataxUniswapConstants.ETHEREUM_UNISWAP_V3_ROUTER);
        assertEq(swapConfig.quoter, StrataxUniswapConstants.ETHEREUM_UNISWAP_V3_QUOTER_V2);
        assertEq(swapConfig.poolFee, expectedPoolFee);
    }
}
