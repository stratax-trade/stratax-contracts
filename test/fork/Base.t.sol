// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
//import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Stratax} from "../../src/Stratax.sol";
import {StrataxPositionNft} from "../../src/StrataxPositionNft.sol";
import {StrataxOracle} from "../../src/StrataxOracle.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {IPool} from "../../src/interfaces/external/IPool.sol";
import {ConstantsEtMainnet} from "../Constants.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @title StrataxForkTestBase
 * @notice Base contract for Stratax fork tests containing shared setup and utilities
 * @dev Inherit from this contract in fork test files
 */
abstract contract StrataxForkTestBase is Test, ConstantsEtMainnet {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    Stratax public stratax;
    Stratax public strataxImplementation;
    UpgradeableBeacon public strataxBeacon;
    StrataxPositionNft public strataxPositionNft;
    StrataxPositionNft public strataxPositionNftImplementation;
    TransparentUpgradeableProxy public nftProxy;
    ProxyAdmin public proxyAdmin;
    StrataxOracle public strataxOracle;
    FeeCollector public feeCollector;
    FeeCollector public feeCollectorImplementation;
    TransparentUpgradeableProxy public feeCollectorProxy;
    address public ownerTrader;
    uint256 public tokenId;
    address public admin;

    uint256 public SAVED_DATA_BLOCK;

    bool hasApiKey;
    bool usesSavedData;

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
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
        admin = makeAddr("admin");

        // Deploy ProxyAdmin first (needed for all proxies)
        proxyAdmin = new ProxyAdmin(address(this));

        strataxOracle = new StrataxOracle();
        strataxOracle.setPriceFeed(USDC, USDC_PRICE_FEED);
        strataxOracle.setPriceFeed(WETH, WETH_PRICE_FEED);

        // Deploy FeeCollector implementation and proxy
        feeCollectorImplementation = new FeeCollector();
        bytes memory feeCollectorInitData = abi.encodeWithSelector(
            FeeCollector.initialize.selector,
            admin, // owner
            5 // strataxFee in basis points (0.05%)
        );
        feeCollectorProxy = new TransparentUpgradeableProxy(
            address(feeCollectorImplementation), address(proxyAdmin), feeCollectorInitData
        );
        feeCollector = FeeCollector(address(feeCollectorProxy));

        // Deploy Stratax implementation and beacon
        strataxImplementation = new Stratax();
        strataxBeacon = new UpgradeableBeacon(address(strataxImplementation), address(this));

        // Deploy StrataxPositionNft implementation
        strataxPositionNftImplementation = new StrataxPositionNft();

        // Initialize StrataxPositionNft via TransparentUpgradeableProxy
        StrataxPositionNft.StrataxPositionNftInitParams memory nftParams =
            StrataxPositionNft.StrataxPositionNftInitParams({
                strataxBeacon: address(strataxBeacon),
                aavePool: AAVE_POOL,
                aaveDataProvider: AAVE_PROTOCOL_DATA_PROVIDER,
                oneInchRouter: INCH_ROUTER,
                strataxOracle: address(strataxOracle),
                feeCollector: address(feeCollector),
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
                // forge-lint: disable-next-line(unsafe-typecast)
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
