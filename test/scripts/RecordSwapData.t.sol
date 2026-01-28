// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Stratax} from "../../src/Stratax.sol";
import {StrataxOracle} from "../../src/StrataxOracle.sol";
import {IPool} from "../../src/interfaces/external/IPool.sol";
import {ConstantsEtMainnet} from "../Constants.t.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/// @notice Test that records actual swap data used during test execution
/// @dev Run via: node test/scripts/calculate_and_save_swap_data.js
/// @dev This test is meant to be run from the node script to record swap data with real 1inch API
contract RecordSwapData is Test, ConstantsEtMainnet {
    Stratax public stratax;
    StrataxOracle public strataxOracle;
    address public ownerTrader;

    function setUp() public {
        ownerTrader = address(0x123);

        strataxOracle = new StrataxOracle();
        strataxOracle.setPriceFeed(USDC, USDC_PRICE_FEED);
        strataxOracle.setPriceFeed(WETH, WETH_PRICE_FEED);

        // Deploy implementation
        Stratax strataxImplementation = new Stratax();

        // Deploy beacon
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(strataxImplementation), address(this));

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            Stratax.initialize.selector,
            AAVE_POOL,
            AAVE_PROTOCOL_DATA_PROVIDER,
            INCH_ROUTER,
            USDC,
            address(strataxOracle)
        );

        // Deploy proxy
        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);

        // Cast proxy to Stratax interface
        stratax = Stratax(address(proxy));

        // Transfer ownership to ownerTrader
        stratax.transferOwnership(ownerTrader);
    }

    /// @notice Get 1inch swap data via FFI
    function get1inchSwapData(address fromToken, address toToken, uint256 amount)
        internal
        returns (bytes memory swapData, string memory key)
    {
        string[] memory inputs = new string[](6);
        inputs[0] = "node";
        inputs[1] = "test/scripts/get_1inch_swap.js";
        inputs[2] = vm.toString(fromToken);
        inputs[3] = vm.toString(toToken);
        inputs[4] = vm.toString(amount);
        inputs[5] = vm.toString(address(stratax));

        bytes memory result = vm.ffi(inputs);
        string memory jsonResponse = string(result);

        bytes memory dataBytes = vm.parseJson(jsonResponse, ".tx.data");
        swapData = abi.decode(dataBytes, (bytes));

        // Create the key for this swap
        string memory fromSymbol = fromToken == WETH ? "WETH" : "USDC";
        string memory toSymbol = toToken == WETH ? "WETH" : "USDC";
        key = string.concat(fromSymbol, "_to_", toSymbol, "_", vm.toString(amount));

        return (swapData, key);
    }

    /// @notice Record swap data by running actual test with 1inch API
    function test_RecordActualSwapData() public {
        console.log("SWAP_DATA_RECORD_START");
        console.log("BLOCK_NUMBER:", block.number);

        uint256 collateralAmount = 1000 * 10 ** 6;

        // Calculate params for opening position
        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.TradeDetails({
                collateralToken: address(USDC),
                borrowToken: address(WETH),
                desiredLeverage: 30_000,
                collateralAmount: collateralAmount,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0,
                collateralTokenDec: 6,
                borrowTokenDec: 18
            })
        );

        // Get swap data for opening position (WETH -> USDC)
        (bytes memory openSwapData, string memory openKey) = get1inchSwapData(WETH, USDC, borrowAmount);
        console.log("SWAP_START");
        console.log("KEY:", openKey);
        console.log("FROM_TOKEN:", WETH);
        console.log("TO_TOKEN:", USDC);
        console.log("FROM_AMOUNT:", borrowAmount);
        console.log("SWAP_DATA:", vm.toString(openSwapData));
        console.log("SWAP_END");

        // Open the position
        deal(USDC, ownerTrader, collateralAmount);
        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateralAmount);
        stratax.createLeveragedPosition(
            USDC, flashLoanAmount, collateralAmount, WETH, borrowAmount, openSwapData, (flashLoanAmount * 950) / 1000
        );

        // Calculate unwind params
        (uint256 collateralToWithdraw, uint256 debtAmount) = stratax.calculateUnwindParams(USDC, WETH);

        // Get swap data for unwinding position (USDC -> WETH)
        (bytes memory unwindSwapData, string memory unwindKey) = get1inchSwapData(USDC, WETH, collateralToWithdraw);
        console.log("SWAP_START");
        console.log("KEY:", unwindKey);
        console.log("FROM_TOKEN:", USDC);
        console.log("TO_TOKEN:", WETH);
        console.log("FROM_AMOUNT:", collateralToWithdraw);
        console.log("SWAP_DATA:", vm.toString(unwindSwapData));
        console.log("SWAP_END");

        vm.stopPrank();

        console.log("SWAP_DATA_RECORD_END");
    }
}
