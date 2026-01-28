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
import {Vm} from "forge-std/Vm.sol";

/**
 * @title StrataxForkTest
 * @notice Fork tests for Stratax leveraged positions
 * @dev Run with: forge test --match-contract StrataxForkTest
 */
contract StrataxForkTest is Test, ConstantsEtMainnet {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    Stratax public stratax;
    Stratax public strataxImplementation;
    UpgradeableBeacon public beacon;
    BeaconProxy public proxy;
    StrataxOracle public strataxOracle;
    address public ownerTrader;

    uint256 public SAVED_DATA_BLOCK;

    bool hasApiKey;
    bool usesSavedData;

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Check if 1inch API key is available first
        try vm.envString("INCH_API_KEY") returns (string memory apiKey) {
            hasApiKey = bytes(apiKey).length > 0;
        } catch {
            hasApiKey = false;
        }

        // Select a random saved block from available files (only needed if no API key)
        if (!hasApiKey) {
            SAVED_DATA_BLOCK = getRandomSavedBlock();
        }

        // Ensure the test is run as a fork
        if (block.number < 1000000) {
            // We're not on a fork, need to create one
            try vm.envString("ETH_RPC_URL") returns (string memory rpcUrl) {
                if (hasApiKey) {
                    // With API key: fork at latest block
                    vm.createSelectFork(rpcUrl);
                    usesSavedData = false;
                } else {
                    // Without API key: fork at saved data block
                    vm.createSelectFork(rpcUrl, SAVED_DATA_BLOCK);
                    usesSavedData = true;
                }
            } catch {
                revert("Fork tests require ETH_RPC_URL environment variable");
            }
        } else {
            // Already on a fork
            usesSavedData = !hasApiKey;
        }

        console.log("Current fork block number is:", block.number);

        ownerTrader = address(0x123);

        strataxOracle = new StrataxOracle();
        strataxOracle.setPriceFeed(USDC, USDC_PRICE_FEED);
        strataxOracle.setPriceFeed(WETH, WETH_PRICE_FEED);

        // Deploy implementation
        strataxImplementation = new Stratax();

        // Deploy beacon
        beacon = new UpgradeableBeacon(address(strataxImplementation), address(this));

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
        proxy = new BeaconProxy(address(beacon), initData);

        // Cast proxy to Stratax interface
        stratax = Stratax(address(proxy));

        // Transfer ownership to ownerTrader
        stratax.transferOwnership(ownerTrader);
    }

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
        }
    }

    function test_Example_SwapWithRealData() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        uint256 collateralAmount = 1000 * 10 ** 6;
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

        (bytes memory swapData,) = get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        deal(USDC, ownerTrader, collateralAmount);

        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateralAmount);
        stratax.createLeveragedPosition(
            USDC, flashLoanAmount, collateralAmount, WETH, borrowAmount, swapData, (flashLoanAmount * 950) / 1000
        );
        vm.stopPrank();

        _verifyPosition(address(stratax));
    }

    function test_OpenAndUnwindPosition() public {
        if (!hasApiKey && !usesSavedData) {
            vm.skip(true);
        }

        // Open position
        uint256 collateralAmount = 1000 * 10 ** 6;
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

        (bytes memory openSwapData,) = get1inchSwapData(WETH, USDC, borrowAmount, address(stratax));

        deal(USDC, ownerTrader, collateralAmount);

        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateralAmount);
        stratax.createLeveragedPosition(
            USDC, flashLoanAmount, collateralAmount, WETH, borrowAmount, openSwapData, (flashLoanAmount * 950) / 1000
        );

        (uint256 totalCollateralAfterOpen, uint256 totalDebtAfterOpen,,,, uint256 healthFactorAfterOpen) =
            IPool(AAVE_POOL).getUserAccountData(address(stratax));

        assertTrue(totalCollateralAfterOpen > 0, "Should have collateral");
        assertTrue(totalDebtAfterOpen > 0, "Should have debt");
        assertTrue(healthFactorAfterOpen > 1e18, "Health factor should be above 1");

        // Unwind position
        console.log("Unwind: calculating params");
        (uint256 collateralToWithdraw, uint256 debtAmount) = stratax.calculateUnwindParams(USDC, WETH);
        console.log("Unwind: get 1inch data");
        (bytes memory unwindSwapData,) = get1inchSwapData(USDC, WETH, collateralToWithdraw, address(stratax));
        console.log("Unwind: calling stratax to unwind position");
        stratax.unwindPosition(USDC, collateralToWithdraw, WETH, debtAmount, unwindSwapData, (debtAmount * 950) / 1000);

        vm.stopPrank();

        (, uint256 totalDebtAfterUnwind,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));

        assertTrue(totalDebtAfterUnwind < totalDebtAfterOpen, "Debt should be reduced");
        assertTrue(
            IERC20(USDC).balanceOf(ownerTrader) > 0 || IERC20(WETH).balanceOf(ownerTrader) > 0,
            "User should receive tokens back"
        );
    }

    /*//////////////////////////////////////////////////////////////
                            UTILITIES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get a random block number from available swap data files
     * @return uint256 Randomly selected block number
     */
    function getRandomSavedBlock() internal view returns (uint256) {
        string memory root = vm.projectRoot();
        string memory fixturesPath = string.concat(root, "/test/fixtures");

        Vm.DirEntry[] memory entries = vm.readDir(fixturesPath);

        uint256[] memory blockNumbers = new uint256[](entries.length);
        uint256 count = 0;

        // Parse block numbers from filenames like "swap_data_block_24329289.json"
        for (uint256 i = 0; i < entries.length; i++) {
            string memory filename = entries[i].path;
            bytes memory filenameBytes = bytes(filename);

            // Extract just the filename (after last /)
            uint256 lastSlash = 0;
            for (uint256 j = 0; j < filenameBytes.length; j++) {
                if (filenameBytes[j] == bytes1("/")) {
                    lastSlash = j + 1;
                }
            }

            if (lastSlash > 0 && lastSlash < filenameBytes.length) {
                string memory basename = substring(filename, lastSlash, filenameBytes.length);
                bytes memory basenameBytes = bytes(basename);

                // Check if filename starts with "swap_data_block_" and ends with ".json"
                if (basenameBytes.length > 21) {
                    string memory prefix = substring(basename, 0, 16);
                    string memory suffix = substring(basename, basenameBytes.length - 5, basenameBytes.length);

                    if (
                        keccak256(bytes(prefix)) == keccak256("swap_data_block_")
                            && keccak256(bytes(suffix)) == keccak256(".json")
                    ) {
                        // Extract block number (between "swap_data_block_" and ".json")
                        string memory blockStr = substring(basename, 16, basenameBytes.length - 5);
                        uint256 blockNum = vm.parseUint(blockStr);
                        blockNumbers[count] = blockNum;
                        count++;
                    }
                }
            }
        }

        require(count > 0, "No swap data files found in test/fixtures/");

        // Pick a random block from the available ones
        uint256 randomIndex = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao))) % count;
        uint256 selectedBlock = blockNumbers[randomIndex];

        console.log("Available swap data files:", count);
        console.log("Randomly selected block:", selectedBlock);

        return selectedBlock;
    }

    /**
     * @notice Helper function to extract substring
     * @param str The string to extract from
     * @param startIndex The starting index (inclusive)
     * @param endIndex The ending index (exclusive)
     * @return string memory The extracted substring
     */
    function substring(string memory str, uint256 startIndex, uint256 endIndex) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }

    /**
     * @notice Load saved swap data from JSON file
     * @param fromToken The token being swapped from
     * @param toToken The token being swapped to
     * @param amount The amount being swapped
     * @return swapData The encoded swap calldata
     * @return expectedAmount The expected output amount (0 for saved data)
     */
    function getSavedSwapData(address fromToken, address toToken, uint256 amount)
        internal
        view
        returns (bytes memory swapData, uint256 expectedAmount)
    {
        string memory root = vm.projectRoot();
        string memory path =
            string.concat(root, "/test/fixtures/swap_data_block_", vm.toString(SAVED_DATA_BLOCK), ".json");
        string memory json = vm.readFile(path);

        // Create lookup key: "SYMBOL_to_SYMBOL_AMOUNT"
        string memory fromSymbol = fromToken == WETH ? "WETH" : "USDC";
        string memory toSymbol = toToken == WETH ? "WETH" : "USDC";
        string memory key = string.concat(".swaps.", fromSymbol, "_to_", toSymbol, "_", vm.toString(amount));

        // Parse the swap data
        bytes memory swapDataBytes = vm.parseJson(json, string.concat(key, ".swapData"));
        swapData = abi.decode(swapDataBytes, (bytes));

        // toAmount is not saved in our JSON format, so return 0
        // The actual amount will be determined by the swap execution
        expectedAmount = 0;
    }

    /**
     * @notice Helper function to get 1inch swap data (via API or saved data)
     * @param fromToken The token being swapped from
     * @param toToken The token being swapped to
     * @param amount The amount being swapped
     * @param fromAddress The address initiating the swap
     * @return swapData The encoded swap calldata
     * @return expectedAmount The expected output amount
     */
    function get1inchSwapData(address fromToken, address toToken, uint256 amount, address fromAddress)
        internal
        returns (bytes memory swapData, uint256 expectedAmount)
    {
        // If no API key and we're using saved data, try to get it from saved data
        if (!hasApiKey && usesSavedData) {
            (swapData, expectedAmount) = getSavedSwapData(fromToken, toToken, amount);
            // If we found saved data, return it
            if (swapData.length > 0) {
                return (swapData, expectedAmount);
            }
            // Otherwise, skip the test since we can't get fresh data without API key
            vm.skip(true);
        }

        string[] memory inputs = new string[](6);
        inputs[0] = "node";
        inputs[1] = "test/scripts/get_1inch_swap.js";
        inputs[2] = vm.toString(fromToken);
        inputs[3] = vm.toString(toToken);
        inputs[4] = vm.toString(amount);
        inputs[5] = vm.toString(fromAddress);

        bytes memory result = vm.ffi(inputs);
        string memory jsonResponse = string(result);

        bytes memory errorCheck = vm.parseJson(jsonResponse, ".error");
        if (errorCheck.length > 0) {
            string memory errorMsg = abi.decode(errorCheck, (string));
            revert(errorMsg);
        }

        bytes memory dataBytes = vm.parseJson(jsonResponse, ".tx.data");
        swapData = abi.decode(dataBytes, (bytes));

        bytes memory toAmountBytes = vm.parseJson(jsonResponse, ".toAmount");
        expectedAmount = abi.decode(toAmountBytes, (uint256));

        return (swapData, expectedAmount);
    }

    /**
     * @notice Helper function to verify position
     * @param _user The user address to check
     */
    function _verifyPosition(address _user) internal view {
        (uint256 totalCollateral,,,,, uint256 healthFactor) = IPool(AAVE_POOL).getUserAccountData(_user);

        assertTrue(totalCollateral > 0, "Should have collateral");
        assertTrue(healthFactor > 1e18, "Health factor should be above 1");
    }
}
