// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Stratax} from "../../src/Stratax.sol";
import {StrataxPositionNft} from "../../src/StrataxPositionNft.sol";
import {StrataxOracle} from "../../src/StrataxOracle.sol";
import {IPool} from "../../src/interfaces/external/IPool.sol";
import {ConstantsEtMainnet} from "../Constants.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/// @notice Test that records actual swap data used during test execution
/// @dev Run via: node test/scripts/calculate_and_save_swap_data.js
/// @dev This test is meant to be run from the node script to record swap data with real 1inch API
contract RecordSwapData is Test, ConstantsEtMainnet {
    Stratax public stratax;
    StrataxOracle public strataxOracle;
    StrataxPositionNft public strataxPositionNft;
    address public ownerTrader;
    uint256 public tokenId;

    function setUp() public {
        ownerTrader = address(0x123);

        strataxOracle = new StrataxOracle();
        strataxOracle.setPriceFeed(USDC, USDC_PRICE_FEED);
        strataxOracle.setPriceFeed(WETH, WETH_PRICE_FEED);

        // Deploy Stratax implementation and beacon
        Stratax strataxImplementation = new Stratax();
        UpgradeableBeacon strataxBeacon = new UpgradeableBeacon(address(strataxImplementation), address(this));

        // Deploy StrataxPositionNft implementation
        StrataxPositionNft strataxPositionNftImplementation = new StrataxPositionNft();

        // Deploy ProxyAdmin
        ProxyAdmin proxyAdmin = new ProxyAdmin(address(this));

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
        TransparentUpgradeableProxy nftProxy = new TransparentUpgradeableProxy(
            address(strataxPositionNftImplementation), address(proxyAdmin), nftInitData
        );
        strataxPositionNft = StrataxPositionNft(address(nftProxy));

        // Mint position NFT which deploys Stratax proxy
        StrataxPositionNft.InitPositionParams memory emptyParams;
        (uint256 _tokenId, address strataxProxy) =
            strataxPositionNft.mintPositionNft(ownerTrader, USDC, WETH, false, emptyParams);
        tokenId = _tokenId;
        stratax = Stratax(strataxProxy);
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
            Stratax.CalcOpenParams({
                desiredLeverage: 30_000,
                collateralAmount: collateralAmount,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
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
            flashLoanAmount, collateralAmount, borrowAmount, openSwapData, (flashLoanAmount * 950) / 1000
        );

        // Calculate unwind params
        (
            uint256 collateralToWithdraw,
            /* uint256 debtAmount */, /*  uint256 strataxFee */
        ) = stratax.calculateUnwindParams(type(uint256).max);

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
