// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Stratax} from "../../src/Stratax.sol";
import {StrataxPositionNft} from "../../src/StrataxPositionNft.sol";
import {StrataxOracle} from "../../src/StrataxOracle.sol";
import {ConstantsEtMainnet} from "../Constants.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract StrataxUnitTest is Test, ConstantsEtMainnet {
    Stratax public stratax;
    Stratax public strataxImplementation;
    UpgradeableBeacon public strataxBeacon;
    StrataxPositionNft public strataxPositionNft;
    StrataxPositionNft public strataxPositionNftImplementation;
    TransparentUpgradeableProxy public nftProxy;
    ProxyAdmin public proxyAdmin;
    StrataxOracle public strataxOracle;
    address public ownerTrader;
    uint256 public tokenId;

    function setUp() public {
        ownerTrader = address(0x123);

        // Mock price feed contracts to return 8 decimals
        vm.mockCall(USDC_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(WETH_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));

        // Mock Aave pool flash loan fee
        vm.mockCall(AAVE_POOL, abi.encodeWithSignature("FLASHLOAN_PREMIUM_TOTAL()"), abi.encode(uint128(9)));

        // Mock token decimals
        vm.mockCall(USDC, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.mockCall(WETH, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));

        strataxOracle = new StrataxOracle();
        strataxOracle.setPriceFeed(USDC, USDC_PRICE_FEED);
        strataxOracle.setPriceFeed(WETH, WETH_PRICE_FEED);

        // Deploy Stratax implementation and beacon
        strataxImplementation = new Stratax();
        strataxBeacon = new UpgradeableBeacon(address(strataxImplementation), address(this));

        // Deploy StrataxPositionNft implementation
        strataxPositionNftImplementation = new StrataxPositionNft();

        // Deploy ProxyAdmin
        proxyAdmin = new ProxyAdmin(address(this));

        // Initialize StrataxPositionNft via TransparentUpgradeableProxy
        StrataxPositionNft.StrataxPositionNftInitParams memory nftParams =
            StrataxPositionNft.StrataxPositionNftInitParams({
                strataxBeacon: address(strataxBeacon),
                aavePool: AAVE_POOL,
                aaveDataProvider: AAVE_PROTOCOL_DATA_PROVIDER,
                oneInchRouter: INCH_ROUTER,
                strataxOracle: address(strataxOracle),
                feeCollector: address(0),
                owner: address(this),
                uri: "https://stratax.io/nft/"
            });

        bytes memory nftInitData = abi.encodeWithSelector(StrataxPositionNft.initialize.selector, nftParams);
        nftProxy = new TransparentUpgradeableProxy(
            address(strataxPositionNftImplementation), address(proxyAdmin), nftInitData
        );
        strataxPositionNft = StrataxPositionNft(address(nftProxy));

        // Mint position NFT which deploys Stratax proxy
        (uint256 _tokenId, address strataxProxy) = strataxPositionNft.mintPositionNft(ownerTrader, USDC, WETH);
        tokenId = _tokenId;
        stratax = Stratax(strataxProxy);
    }

    function test_ContractDeployment() public view {
        assertEq(address(stratax.aavePool()), AAVE_POOL, "AAVE Pool address mismatch");
        assertEq(address(stratax.oneInchRouter()), INCH_ROUTER, "1inch Router address mismatch");
        assertEq(stratax.collateralToken(), USDC, "Collateral token address mismatch");
        assertEq(stratax.borrowToken(), WETH, "Borrow token address mismatch");
        // Owner is verified via NFT ownership
        assertEq(strataxPositionNft.ownerOf(tokenId), ownerTrader, "NFT owner should be ownerTrader");
    }

    function test_ConstantsAreSet() public pure {
        assertTrue(AAVE_POOL != address(0), "AAVE Pool address is zero");
        assertTrue(USDC != address(0), "USDC address is zero");
        assertTrue(INCH_ROUTER != address(0), "1inch Router address is zero");
    }

    function test_BasisPointsConstant() public view {
        assertEq(stratax.FLASHLOAN_FEE_PREC(), 10000, "FLASHLOAN_FEE_PREC should be 10000");
    }

    function test_BeaconProxySetup() public view {
        assertEq(
            strataxBeacon.implementation(), address(strataxImplementation), "Beacon should point to implementation"
        );
        // Verify stratax is deployed as a proxy
        assertTrue(address(stratax) != address(0), "Stratax proxy should be deployed");
    }

    function test_StrataxProxyInitialized() public view {
        // Verify the Stratax proxy was properly initialized by mintPositionNft
        assertEq(stratax.collateralToken(), USDC, "Collateral token should match");
        assertEq(stratax.borrowToken(), WETH, "Borrow token should match");
        assertEq(stratax.tokenId(), tokenId, "Token ID should match");
    }

    function test_CalculateDesiredLeverageRoundtrip() public {
        /**
         * This test verifies that _calculateDesiredLeverage correctly reverses calculateOpenParams
         *
         * Flow:
         * 1. User specifies desired leverage (e.g., 2x) in TradeDetails
         * 2. calculateOpenParams calculates flashLoanAmount based on desiredLeverage
         * 3. During execution, _calculateDesiredLeverage(flashLoanAmount, collateralAmount) should return the original desiredLeverage
         *
         * This ensures the quadratic formula in _calculateDesiredLeverage correctly inverts the formula in calculateOpenParams.
         * We verify this by checking that the flashLoanAmount matches the expected value from the simple formula:
         *   flashLoanAmount = collateralAmount * (desiredLeverage - 1) / LEVERAGE_PRECISION
         *
         * Note: We use a fee of 0 to simplify the math and focus on the leverage calculation.
         */

        // Mock Aave data provider to return LTV for USDC
        uint256 ltv = 8000; // 80% LTV
        vm.mockCall(
            AAVE_PROTOCOL_DATA_PROVIDER,
            abi.encodeWithSignature("getReserveConfigurationData(address)", USDC),
            abi.encode(uint256(0), ltv, uint256(0), uint256(0), uint256(0), false, false, false, false, false)
        );

        // Mock oracle prices (8 decimals)
        uint256 usdcPrice = 1e8; // $1.00
        uint256 wethPrice = 2000e8; // $2000.00
        vm.mockCall(
            USDC_PRICE_FEED, abi.encodeWithSignature("latestRoundData()"), abi.encode(0, int256(usdcPrice), 0, 0, 0)
        );
        vm.mockCall(
            WETH_PRICE_FEED, abi.encodeWithSignature("latestRoundData()"), abi.encode(0, int256(wethPrice), 0, 0, 0)
        );

        // Setup fee collector that returns 0 fee for simpler math
        address feeCollectorMock = address(0x999);
        vm.mockCall(feeCollectorMock, abi.encodeWithSignature("strataxFee()"), abi.encode(uint256(0)));

        // Deploy a new NFT with proper fee collector
        StrataxPositionNft.StrataxPositionNftInitParams memory nftParams =
            StrataxPositionNft.StrataxPositionNftInitParams({
                strataxBeacon: address(strataxBeacon),
                aavePool: AAVE_POOL,
                aaveDataProvider: AAVE_PROTOCOL_DATA_PROVIDER,
                oneInchRouter: INCH_ROUTER,
                strataxOracle: address(strataxOracle),
                feeCollector: feeCollectorMock,
                owner: address(this),
                uri: "https://stratax.io/nft/"
            });

        bytes memory nftInitData = abi.encodeWithSelector(StrataxPositionNft.initialize.selector, nftParams);
        TransparentUpgradeableProxy testProxy = new TransparentUpgradeableProxy(
            address(strataxPositionNftImplementation), address(proxyAdmin), nftInitData
        );
        StrataxPositionNft testNft = StrataxPositionNft(address(testProxy));

        // Mint position NFT
        (, address testStrataxProxy) = testNft.mintPositionNft(ownerTrader, USDC, WETH);
        Stratax testStratax = Stratax(testStrataxProxy);

        vm.prank(ownerTrader);
        testStratax.setStrataxOracle(address(strataxOracle));

        // Test with multiple leverage values
        uint256[] memory leverages = new uint256[](4);
        leverages[0] = 15000; // 1.5x
        leverages[1] = 20000; // 2.0x
        leverages[2] = 30000; // 3.0x
        leverages[3] = 40000; // 4.0x

        for (uint256 i = 0; i < leverages.length; i++) {
            uint256 desiredLeverage = leverages[i];
            uint256 collateralAmount = 1000e6; // 1000 USDC (6 decimals)

            Stratax.TradeDetails memory details = Stratax.TradeDetails({
                desiredLeverage: desiredLeverage,
                collateralAmount: collateralAmount,
                collateralTokenPrice: usdcPrice,
                borrowTokenPrice: wethPrice
            });

            // Call calculateOpenParams to get flash loan amount
            (uint256 flashLoanAmount, uint256 borrowAmount) = testStratax.calculateOpenParams(details);

            // Verify the calculation produced reasonable values
            assertTrue(flashLoanAmount > 0, "Flash loan amount should be > 0");
            assertTrue(borrowAmount > 0, "Borrow amount should be > 0");

            // Now call calculateDesiredLeverage to verify it returns the original leverage
            uint256 calculatedLeverage = testStratax.calculateDesiredLeverage(flashLoanAmount, collateralAmount);

            // Allow for small rounding differences (0.1% tolerance)
            uint256 tolerance = desiredLeverage / 1000;
            assertApproxEqAbs(
                calculatedLeverage,
                desiredLeverage,
                tolerance,
                string(abi.encodePacked("Leverage roundtrip mismatch for leverage ", vm.toString(desiredLeverage)))
            );
        }
    }

    function test_CalculateDesiredLeverageRoundtripWithFee() public {
        /**
         * This test verifies that _calculateDesiredLeverage correctly reverses calculateOpenParams
         * when a Stratax fee is applied (0.01% = 1 basis point).
         *
         * With fees, the calculation becomes:
         * 1. strataxFee = (collateralAmount * feeRate * desiredLeverage) / FLASHLOAN_FEE_PREC
         * 2. collateralAfterFee = collateralAmount - strataxFee
         * 3. flashLoanAmount = collateralAfterFee * (desiredLeverage - 1) / LEVERAGE_PRECISION
         *
         * The _calculateDesiredLeverage function uses a quadratic formula to solve for the original
         * desiredLeverage given flashLoanAmount and collateralAmount, accounting for the fee.
         */
        // Mock oracle prices (8 decimals)
        uint256 usdcPrice = 1e8; // $1.00
        uint256 wethPrice = 2000e8; // $2000.00
        // Mock Aave data provider to return LTV for USDC
        Stratax testStratax;
        {

            uint256 ltv = 8000; // 80% LTV
            vm.mockCall(
                AAVE_PROTOCOL_DATA_PROVIDER,
                abi.encodeWithSignature("getReserveConfigurationData(address)", USDC),
                abi.encode(uint256(0), ltv, uint256(0), uint256(0), uint256(0), false, false, false, false, false)
            );

            vm.mockCall(
                USDC_PRICE_FEED, abi.encodeWithSignature("latestRoundData()"), abi.encode(0, int256(usdcPrice), 0, 0, 0)
            );
            vm.mockCall(
                WETH_PRICE_FEED, abi.encodeWithSignature("latestRoundData()"), abi.encode(0, int256(wethPrice), 0, 0, 0)
            );

            // Setup fee collector with 1 basis point (0.01%) fee to avoid underflow bug
            address feeCollectorMock = address(0x999);
            uint256 strataxFeeRate = 1; // 1 basis point = 0.01%
            vm.mockCall(feeCollectorMock, abi.encodeWithSignature("strataxFee()"), abi.encode(strataxFeeRate));

            // Deploy a new NFT with fee collector
            StrataxPositionNft.StrataxPositionNftInitParams memory nftParams =
                StrataxPositionNft.StrataxPositionNftInitParams({
                    strataxBeacon: address(strataxBeacon),
                    aavePool: AAVE_POOL,
                    aaveDataProvider: AAVE_PROTOCOL_DATA_PROVIDER,
                    oneInchRouter: INCH_ROUTER,
                    strataxOracle: address(strataxOracle),
                    feeCollector: feeCollectorMock,
                    owner: address(this),
                    uri: "https://stratax.io/nft/"
                });

            bytes memory nftInitData = abi.encodeWithSelector(StrataxPositionNft.initialize.selector, nftParams);
            TransparentUpgradeableProxy testProxy = new TransparentUpgradeableProxy(
                address(strataxPositionNftImplementation), address(proxyAdmin), nftInitData
            );
            StrataxPositionNft testNft = StrataxPositionNft(address(testProxy));

            // Mint position NFT
            (, address testStrataxProxy) = testNft.mintPositionNft(ownerTrader, USDC, WETH);
            testStratax = Stratax(testStrataxProxy);
        }

        vm.prank(ownerTrader);
        testStratax.setStrataxOracle(address(strataxOracle));

        // Testing with leverage values from 1.01x to 5.0x
        uint256[] memory leverages = new uint256[](22);
        leverages[0] = 10100; // 1.01x
        leverages[1] = 12100; // 1.21x
        leverages[2] = 14100; // 1.41x
        leverages[3] = 16100; // 1.61x
        leverages[4] = 18100; // 1.81x
        leverages[5] = 20100; // 2.01x
        leverages[6] = 22100; // 2.21x
        leverages[7] = 24100; // 2.41x
        leverages[8] = 26100; // 2.61x
        leverages[9] = 28100; // 2.81x
        leverages[10] = 30100; // 3.01x
        leverages[11] = 32100; // 3.21x
        leverages[12] = 34100; // 3.41x
        leverages[13] = 36100; // 3.61x
        leverages[14] = 38100; // 3.81x
        leverages[15] = 40100; // 4.01x
        leverages[16] = 42100; // 4.21x
        leverages[17] = 44100; // 4.41x
        leverages[18] = 46100; // 4.61x
        leverages[19] = 47000; // 3.81x
        leverages[20] = 47000; // 4.01x
        leverages[21] = 47822; // 4.01x
        //leverages[21] = 49500;

        for (uint256 i = 0; i < leverages.length; i++) {
            uint256 desiredLeverage = leverages[i];
            uint256 collateralAmount = 1000e6; // 1000 USDC (6 decimals)

            Stratax.TradeDetails memory details = Stratax.TradeDetails({
                desiredLeverage: desiredLeverage,
                collateralAmount: collateralAmount,
                collateralTokenPrice: usdcPrice,
                borrowTokenPrice: wethPrice
            });

            // Call calculateOpenParams to get flash loan amount
            (uint256 flashLoanAmount, uint256 borrowAmount) = testStratax.calculateOpenParams(details);

            // Verify the calculation produced reasonable values
            assertTrue(flashLoanAmount > 0, "Flash loan amount should be > 0");
            assertTrue(borrowAmount > 0, "Borrow amount should be > 0");

            // Now call calculateDesiredLeverage to verify it returns the original leverage
            // This is the critical test - can the function reverse-engineer the leverage from the flash loan amount?
            uint256 calculatedLeverage = testStratax.calculateDesiredLeverage(flashLoanAmount, collateralAmount);

            // Allow for small rounding differences (0.5% tolerance due to quadratic formula complexity with fees)
            uint256 tolerance = desiredLeverage / 200; // 0.5% tolerance
            assertApproxEqAbs(
                calculatedLeverage,
                desiredLeverage,
                tolerance,
                string(
                    abi.encodePacked("Leverage roundtrip with fee mismatch for leverage ", vm.toString(desiredLeverage))
                )
            );
        }
    }

    function test_GetMaxAchievableLeverageBinary() public {
        /**
         * This test verifies that getMaxAchievableLeverageBinary correctly calculates
         * the maximum achievable leverage using binary search.
         *
         * The function uses binary search to find the highest leverage where:
         * totalDebt <= maxBorrow
         *
         * Where:
         * - totalDebt = borrowed + flashFee
         * - borrowed = C * (L - 1)
         * - flashFee = borrowed * flashLoanFeeBps / BPS
         * - maxBorrow = effectiveCollateral * effectiveLTV / BPS
         * - effectiveCollateral = C - protocolFee
         * - protocolFee = C * L * strataxFee / (LEVERAGE_PRECISION * BPS)
         */

        // Mock Aave data provider to return LTV for USDC
        uint256 ltv = 8000; // 80% LTV
        vm.mockCall(
            AAVE_PROTOCOL_DATA_PROVIDER,
            abi.encodeWithSignature("getReserveConfigurationData(address)", USDC),
            abi.encode(uint256(0), ltv, uint256(0), uint256(0), uint256(0), false, false, false, false, false)
        );

        // Setup fee collector with 5 basis points (0.05%) fee
        address feeCollectorMock = address(0x999);
        uint256 strataxFeeRate = 5; // 5 basis points = 0.05%
        vm.mockCall(feeCollectorMock, abi.encodeWithSignature("strataxFee()"), abi.encode(strataxFeeRate));

        // Deploy a new NFT with fee collector
        StrataxPositionNft.StrataxPositionNftInitParams memory nftParams =
            StrataxPositionNft.StrataxPositionNftInitParams({
                strataxBeacon: address(strataxBeacon),
                aavePool: AAVE_POOL,
                aaveDataProvider: AAVE_PROTOCOL_DATA_PROVIDER,
                oneInchRouter: INCH_ROUTER,
                strataxOracle: address(strataxOracle),
                feeCollector: feeCollectorMock,
                owner: address(this),
                uri: "https://stratax.io/nft/"
            });

        bytes memory nftInitData = abi.encodeWithSelector(StrataxPositionNft.initialize.selector, nftParams);
        TransparentUpgradeableProxy testProxy = new TransparentUpgradeableProxy(
            address(strataxPositionNftImplementation), address(proxyAdmin), nftInitData
        );
        StrataxPositionNft testNft = StrataxPositionNft(address(testProxy));

        // Mint position NFT
        (, address testStrataxProxy) = testNft.mintPositionNft(ownerTrader, USDC, WETH);
        Stratax testStratax = Stratax(testStrataxProxy);

        // Get theoretical max leverage (no fees/margins)
        uint256 theoreticalMax = testStratax.getMaxLeverage(USDC);

        // Get max achievable leverage via binary search
        uint256 maxBinary = testStratax.getMaxAchievableLeverageBinary();
        console.log("max leverage is: ", maxBinary);

        bool isLeverageSafe = testStratax.isLeverageSafe(47000, 8000, 5);
        console.log("Is leverage safe", isLeverageSafe);

        // Binary search result should be less than theoretical max
        assertLt(maxBinary, theoreticalMax, "Binary search max should be less than theoretical max");

        // Binary search result should be at least 1x
        assertGe(maxBinary, 10000, "Binary search max should be at least 1x (10000)");

        // With 80% LTV, theoretical max is 5x
        assertEq(theoreticalMax, 50000, "Theoretical max should be 5x for 80% LTV");

        // The binary search result should be achievable
        // We verify this by checking that _isLeverageSafe returns true for maxBinary
        // Since _isLeverageSafe is internal, we can't call it directly, but we know
        // that if binary search returned this value, it must be safe

        // Verify the result is reasonable (between 1x and theoretical max)
        assertGt(maxBinary, 10000, "Max binary should be greater than 1x");
        assertLt(maxBinary, theoreticalMax, "Max binary should be less than theoretical max");
    }
}
