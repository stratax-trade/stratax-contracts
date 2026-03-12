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
        stratax.transfer(address(sale), 500_000e18);
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

    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}
