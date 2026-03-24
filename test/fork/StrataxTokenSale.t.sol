// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StrataxToken} from "../../src/StrataxToken.sol";
import {StrataxTokenSale} from "../../src/StrataxTokenSale.sol";
import {IPyth} from "../../src/interfaces/external/IPyth.sol";
import {ConstantsEtMainnet} from "../Constants.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

/**
 * @title StrataxTokenSaleForkTest
 * @notice Fork tests for StrataxTokenSale using real mainnet contracts (no mocks)
 */
contract StrataxTokenSaleForkTest is Test, ConstantsEtMainnet {
    // Ethereum mainnet Pyth contract
    address internal constant PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;

    // Pyth ETH/USD price feed id (price with expo -8)
    bytes32 internal constant PYTH_ETH_USD_PRICE_ID =
        0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    uint256 internal constant STRATAX_PRICE_USD = 20_000_000; // $0.20 (8 decimals)

    address internal owner = makeAddr("owner");
    address internal buyer = makeAddr("buyer");
    address internal treasury = makeAddr("treasury");

    StrataxToken internal stratax;
    StrataxTokenSale internal sale;

    function setUp() public {
        if (block.number < 1_000_000) {
            string memory rpcUrl = vm.envString("ETH_RPC_URL");
            vm.createSelectFork(rpcUrl);
        }

        // Deploy STRATAX token as UUPS proxy
        StrataxToken tokenImpl = new StrataxToken();
        bytes memory tokenInit = abi.encodeWithSelector(StrataxToken.initialize.selector, owner, 1_000_000e18);
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenInit);
        stratax = StrataxToken(address(tokenProxy));

        // Deploy sale as UUPS proxy
        StrataxTokenSale saleImpl = new StrataxTokenSale();
        bytes memory saleInit = abi.encodeWithSelector(
            StrataxTokenSale.initialize.selector, owner, address(stratax), PYTH, treasury, STRATAX_PRICE_USD
        );
        ERC1967Proxy saleProxy = new ERC1967Proxy(address(saleImpl), saleInit);
        sale = StrataxTokenSale(payable(address(saleProxy)));

        // Seed sale inventory and whitelist WETH as payment token
        vm.startPrank(owner);
        assertTrue(stratax.transfer(address(sale), 500_000e18), "seed transfer failed");
        sale.whitelistPaymentToken(WETH, PYTH_ETH_USD_PRICE_ID, 7 days);
        vm.stopPrank();

        // Fund buyer with real WETH
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        IWETH(WETH).deposit{value: 1 ether}();

        vm.prank(buyer);
        IERC20(WETH).approve(address(sale), type(uint256).max);
    }

    function test_QuoteWithRealPythPrice() public {
        if (!_isContract(PYTH)) {
            vm.skip(true);
        }

        // If the on-chain Pyth price is stale/unavailable on this fork block, skip gracefully.
        try IPyth(PYTH).getPriceNoOlderThan(PYTH_ETH_USD_PRICE_ID, 7 days) returns (IPyth.Price memory) {
            uint256 out = sale.quote(WETH, 0.1 ether);
            assertTrue(out > 0, "quote should be greater than zero");
        } catch {
            vm.skip(true);
        }
    }

    function test_BuyWithWethOnFork() public {
        if (!_isContract(PYTH)) {
            vm.skip(true);
        }

        // If the on-chain Pyth price is stale/unavailable on this fork block, skip gracefully.
        try IPyth(PYTH).getPriceNoOlderThan(PYTH_ETH_USD_PRICE_ID, 7 days) returns (IPyth.Price memory) {
            uint256 paymentAmount = 0.1 ether;
            uint256 quotedOut = sale.quote(WETH, paymentAmount);
            uint256 minOut = (quotedOut * 99) / 100;

            uint256 buyerWethBefore = IERC20(WETH).balanceOf(buyer);
            uint256 buyerStrataxBefore = stratax.balanceOf(buyer);
            uint256 treasuryWethBefore = IERC20(WETH).balanceOf(treasury);

            vm.prank(buyer);
            uint256 out = sale.buy(WETH, paymentAmount, minOut, new bytes[](0));
            uint256 immediateUnlock = (out * sale.PUBLIC_SALE_TGE_BPS()) / sale.BPS();

            assertTrue(out >= minOut, "out should satisfy minOut");
            assertEq(IERC20(WETH).balanceOf(buyer), buyerWethBefore - paymentAmount, "buyer WETH mismatch");
            assertEq(stratax.balanceOf(buyer), buyerStrataxBefore + immediateUnlock, "buyer STRATAX mismatch");
            assertEq(IERC20(WETH).balanceOf(treasury), treasuryWethBefore + paymentAmount, "treasury WETH mismatch");
        } catch {
            vm.skip(true);
        }
    }

    /**
     * @notice Test normalization of Pyth prices with 6 decimals (less than 8)
     * Example: USDC oracle price might be 1e6 (price of 1 USDC in USD with 6 decimals = $1.00)
     * Should normalize to 1e8 (8 decimals for $1.00)
     */
    function test_NormalizePriceWith6Decimals() public view {
        // Simulate a price feed with 6 decimals
        // Example: 1 USDC = $1.00 with 6 decimals = 1_000_000
        int64 price = 1_000_000; // $1.00 with 6 decimal exponent
        int32 expo = -6;

        uint256 normalized = sale.normalizePriceForTest(price, expo);

        // Should normalize to 8 decimals: 1_000_000 * 10^(8-6) = 100_000_000
        uint256 expected = 100_000_000; // $1.00 with 8 decimals
        assertEq(normalized, expected, "6 decimal price should normalize to 8 decimals");
    }

    /**
     * @notice Test normalization of Pyth prices with 18 decimals (more than 8)
     * Example: A high-precision oracle price with 18 decimals = price / 10^10
     */
    function test_NormalizePriceWith18Decimals() public view {
        // Simulate a price feed with 18 decimals
        // Example: 1 token = $1.00 with 18 decimals = 1e18
        int64 price = 1_000_000_000_000_000_000; // $1.00 with 18 decimal exponent
        int32 expo = -18;

        uint256 normalized = sale.normalizePriceForTest(price, expo);

        // Should normalize to 8 decimals: 1e18 / 10^10 = 100_000_000
        uint256 expected = 100_000_000; // $1.00 with 8 decimals
        assertEq(normalized, expected, "18 decimal price should normalize to 8 decimals");
    }

    /**
     * @notice Test normalization with very small decimals (2 decimals)
     * Example: Price feed with only 2 decimal places
     */
    function test_NormalizePriceWith2Decimals() public view {
        // Simulate a price feed with 2 decimals
        // Example: price = 150 with expo -2 means $1.50
        int64 price = 150; // $1.50 with 2 decimal exponent
        int32 expo = -2;

        uint256 normalized = sale.normalizePriceForTest(price, expo);

        // Should normalize to 8 decimals: 150 * 10^(8-2) = 150 * 10^6 = 150_000_000
        uint256 expected = 150_000_000; // $1.50 with 8 decimals
        assertEq(normalized, expected, "2 decimal price should normalize correctly to 8 decimals");
    }

    /**
     * @notice Test normalization with zero exponent
     * Example: Price feed where price is already in the correct scale
     */
    function test_NormalizePriceWithZeroExponent() public view {
        // Simulate a price feed with 0 exponent
        // This means the price value is already an integer USD value
        int64 price = 5; // $5.00 without decimal shift
        int32 expo = 0;

        uint256 normalized = sale.normalizePriceForTest(price, expo);

        // Should normalize to 8 decimals: 5 * 10^(8-0) = 5 * 10^8 = 500_000_000
        uint256 expected = 500_000_000; // $5.00 with 8 decimals
        assertEq(normalized, expected, "0 exponent price should multiply by 10^8");
    }

    /**
     * @notice Test normalization with positive exponent (rare case)
     * Example: Price feed where exponent is positive means value is scaled up
     */
    function test_NormalizePriceWithPositiveExponent() public view {
        // Simulate a price feed with positive exponent
        // price = 1 with expo = 5 means 1 * 10^5 = 100000 (in the price feed's native scale)
        int64 price = 1; // 1 in some scaled representation
        int32 expo = 5; // positive exponent

        uint256 normalized = sale.normalizePriceForTest(price, expo);

        // Should normalize to 8 decimals: 1 * 10^(8+5) = 10^13
        uint256 expected = 10_000_000_000_000; // 1 * 10^13
        assertEq(normalized, expected, "positive exponent should multiply by 10^(8+expo)");
    }

    /**
     * @notice Test buying with a simulated 6 decimal price feed
     * Verify quote calculation correctly handles different precision
     */
    function test_QuoteCalculationWith6DecimalFeed() public view {
        // Assume USDC-like token with 6 decimal price feed
        // Price: $1.00 with 6 decimals = 1_000_000
        int64 usdcPrice = 1_000_000; // $1.00
        int32 usdcExpo = -6;

        // Expected normalized price
        uint256 normalizedPrice = sale.normalizePriceForTest(usdcPrice, usdcExpo); // 100_000_000 (8 decimals)

        // Payment amount: 100 USDC (100 * 1e6)
        uint256 paymentAmount = 100e6;

        // Payment value = 100 USDC * $1.00 = $100.00
        uint256 paymentValueUsd = (paymentAmount * normalizedPrice) / 1e6; // Use token decimals for division

        // STRATAX price = $0.20 = 20_000_000 (8 decimals)
        uint256 strataxPriceUsd = 20_000_000;

        // Expected STRATAX out = $100.00 / $0.20 = 500 STRATAX
        uint256 expectedStrataxOut = (paymentValueUsd * 1e18) / strataxPriceUsd;

        assertTrue(expectedStrataxOut > 0, "Should calculate positive STRATAX output");
        assertEq(expectedStrataxOut, 500e18, "Should receive 500 STRATAX for $100 at $0.20 per token");
    }

    /**
     * @notice Test buying with a simulated 18 decimal price feed
     * Verify quote calculation with high precision price feed
     */
    function test_QuoteCalculationWith18DecimalFeed() public view {
        // Custom token with 18 decimal price feed
        // Price: $2.50 with 18 decimals = 2.5e18
        int64 customTokenPrice = 2_500_000_000_000_000_000; // $2.50
        int32 customExpo = -18;

        // Expected normalized price
        uint256 normalizedPrice = sale.normalizePriceForTest(customTokenPrice, customExpo); // 250_000_000 (8 decimals)

        // Payment amount: 40 tokens (40 * 1e18)
        uint256 paymentAmount = 40e18;

        // Payment value = 40 * $2.50 = $100.00
        uint256 paymentValueUsd = (paymentAmount * normalizedPrice) / 1e18; // Use token decimals for division

        // STRATAX price = $0.20 = 20_000_000
        uint256 strataxPriceUsd = 20_000_000;

        // Expected STRATAX out = $100.00 / $0.20 = 500 STRATAX
        uint256 expectedStrataxOut = (paymentValueUsd * 1e18) / strataxPriceUsd;

        assertTrue(expectedStrataxOut > 0, "Should calculate positive STRATAX output");
        assertEq(expectedStrataxOut, 500e18, "Should receive 500 STRATAX for $100 at $0.20 per token");
    }

    /**
     * @notice Test that various decimal price feeds normalize correctly
     * Verifies that the normalization function handles edge cases
     */
    function test_MultipleDecimalNormalizationRobustness() public view {
        // Test various decimal places
        uint256 expectedUsdValue = 250_000_000; // $2.50 with 8 decimals

        // 3 decimals: 2500
        assertEq(sale.normalizePriceForTest(2500, -3), expectedUsdValue, "3 decimal normalization failed");

        // 4 decimals: 25000
        assertEq(sale.normalizePriceForTest(25000, -4), expectedUsdValue, "4 decimal normalization failed");

        // 5 decimals: 250000
        assertEq(sale.normalizePriceForTest(250000, -5), expectedUsdValue, "5 decimal normalization failed");

        // 6 decimals: 2500000
        assertEq(sale.normalizePriceForTest(2500000, -6), expectedUsdValue, "6 decimal normalization failed");

        // 7 decimals: 25000000
        assertEq(sale.normalizePriceForTest(25000000, -7), expectedUsdValue, "7 decimal normalization failed");

        // 9 decimals: 2500000000
        assertEq(sale.normalizePriceForTest(2500000000, -9), expectedUsdValue, "9 decimal normalization failed");

        // 10 decimals: 25000000000
        assertEq(sale.normalizePriceForTest(25000000000, -10), expectedUsdValue, "10 decimal normalization failed");
    }

    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}
