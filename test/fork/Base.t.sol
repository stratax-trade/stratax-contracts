// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Stratax_Aave_1Inch as Stratax} from "../../src/core/position-types/Stratax_Aave_1Inch.sol";
import {StrataxPositionNft} from "../../src/core/StrataxPositionNft.sol";
import {StrataxConfigManager} from "../../src/core/StrataxConfigManager.sol";
import {StrataxProtocolBeacon} from "../../src/core/StrataxProtocolBeacon.sol";
import {AaveOneInchPositionAdapter} from "../../src/core/adapters/AaveOneInchPositionAdapter.sol";
import {StrataxOracle} from "../../src/core/StrataxOracle.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {StrataxAaveLib} from "../../src/libraries/lending/StrataxAaveLib.sol";
import {Stratax1InchLib} from "../../src/libraries/swapping/Stratax1InchLib.sol";
import {IPool} from "../../src/interfaces/external/IPool.sol";
import {ConstantsEtMainnet} from "../Constants.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @title StrataxForkTestBase
 * @notice Base contract for Stratax fork tests containing shared setup and utilities
 * @dev Inherit from this contract in fork test files
 * @dev Uses the same deployment pattern as DeployStrataxSystem.s.sol:
 *      - StrataxOracle as UUPS (ERC1967Proxy)
 *      - FeeCollector as UUPS (ERC1967Proxy)
 *      - StrataxPositionNft as UUPS (ERC1967Proxy)
 *      - Stratax with UpgradeableBeacon pattern
 */
abstract contract StrataxForkTestBase is Test, ConstantsEtMainnet {
    bytes32 internal constant LENDING_AAVE_V3_ID = keccak256("LENDING:AAVE_V3");
    bytes32 internal constant SWAP_ONEINCH_V6_ID = keccak256("SWAP:ONEINCH_V6");

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // Default configuration values (matching deployment script)
    uint256 public constant DEFAULT_STRATAX_FEE = 5; // 0.05% (5/10000)
    string public constant DEFAULT_NFT_URI = "https://api.stratax.io/nft/metadata/";

    Stratax public stratax;
    Stratax public strataxImplementation;
    UpgradeableBeacon public strataxBeacon;
    StrataxPositionNft public strataxPositionNft;
    StrataxPositionNft public strataxPositionNftImplementation;
    ERC1967Proxy public strataxPositionNftProxy;
    StrataxOracle public strataxOracle;
    StrataxOracle public strataxOracleImplementation;
    ERC1967Proxy public strataxOracleProxy;
    FeeCollector public feeCollector;
    FeeCollector public feeCollectorImplementation;
    ERC1967Proxy public feeCollectorProxy;
    StrataxConfigManager public strataxConfigManager;

    address public ownerTrader;
    address public admin;
    uint256 public tokenId;
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

        // Deploy all contracts using the same pattern as DeployStrataxSystem.s.sol
        deployStrataxOracle(admin);
        deployStrataxBeacon(admin);
        deployFeeCollector(admin, address(0)); // Pass address(0) initially, will be set after NFT deployment
        deployStrataxPositionNft(admin);
        deployStrataxConfigManager(admin);

        _configureDefaultAaveOneInch(
            strataxConfigManager,
            strataxPositionNft,
            address(strataxBeacon),
            IPool(AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL(),
            admin
        );

        // Update FeeCollector with actual StrataxPositionNft address
        vm.prank(admin);
        feeCollector.setStrataxPositionNft(address(strataxPositionNft));

        // Mint position NFT which deploys Stratax proxy
        StrataxPositionNft.MintPositionParams memory emptyParams;
        (uint256 _tokenId, address strataxProxy) = strataxPositionNft.mintPositionByProtocolIds(
            ownerTrader, USDC, WETH, LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID, false, emptyParams
        );
        tokenId = _tokenId;
        stratax = Stratax(strataxProxy);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPLOYMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys StrataxOracle as a UUPS proxy
     * @param owner The address that will own the contract
     */
    function deployStrataxOracle(address owner) internal {
        // Deploy implementation
        strataxOracleImplementation = new StrataxOracle();

        // Encode initialize call
        bytes memory initData = abi.encodeWithSelector(StrataxOracle.initialize.selector, owner);

        // Deploy UUPS proxy
        strataxOracleProxy = new ERC1967Proxy(address(strataxOracleImplementation), initData);
        strataxOracle = StrataxOracle(address(strataxOracleProxy));

        // Setup initial price feeds
        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = WETH;

        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = USDC_PRICE_FEED;
        priceFeeds[1] = WETH_PRICE_FEED;

        vm.prank(owner);
        strataxOracle.setPriceFeeds(tokens, priceFeeds);
    }

    /**
     * @notice Deploys FeeCollector as a UUPS proxy
     * @param owner The address that will own the contract
     * @param strataxPositionNftAddress The StrataxPositionNft address (can be address(0) initially)
     */
    function deployFeeCollector(address owner, address strataxPositionNftAddress) internal {
        // Deploy implementation
        feeCollectorImplementation = new FeeCollector();

        // Encode initialize call with strataxPositionNft parameter
        bytes memory initData = abi.encodeWithSelector(
            FeeCollector.initialize.selector, strataxPositionNftAddress, owner, DEFAULT_STRATAX_FEE
        );

        // Deploy UUPS proxy
        feeCollectorProxy = new ERC1967Proxy(address(feeCollectorImplementation), initData);
        feeCollector = FeeCollector(address(feeCollectorProxy));
    }

    /**
     * @notice Deploys Stratax implementation and Beacon
     * @param owner The address that will own the beacon
     */
    function deployStrataxBeacon(address owner) internal {
        // Deploy implementation
        strataxImplementation = new Stratax();

        // Deploy beacon
        strataxBeacon = UpgradeableBeacon(
            address(
                new StrataxProtocolBeacon(address(strataxImplementation), owner, LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID)
            )
        );
    }

    /**
     * @notice Deploys StrataxPositionNft as a UUPS proxy
     * @param owner The address that will own the contract
     */
    function deployStrataxPositionNft(address owner) internal {
        // Deploy implementation
        strataxPositionNftImplementation = new StrataxPositionNft();

        // Create initialization params
        StrataxPositionNft.StrataxPositionNftInitParams memory initParams =
            StrataxPositionNft.StrataxPositionNftInitParams({
                strataxOracle: address(strataxOracle),
                feeCollector: address(feeCollector),
                configManager: address(this),
                owner: owner,
                uri: DEFAULT_NFT_URI
            });

        // Encode initialize call
        bytes memory initData = abi.encodeWithSelector(StrataxPositionNft.initialize.selector, initParams);

        // Deploy UUPS proxy
        strataxPositionNftProxy = new ERC1967Proxy(address(strataxPositionNftImplementation), initData);
        strataxPositionNft = StrataxPositionNft(address(strataxPositionNftProxy));
    }

    function deployStrataxConfigManager(address owner) internal {
        StrataxConfigManager implementation = new StrataxConfigManager();
        bytes memory initData =
            abi.encodeWithSelector(StrataxConfigManager.initialize.selector, owner, address(strataxPositionNft));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        strataxConfigManager = StrataxConfigManager(address(proxy));
        vm.prank(owner);
        strataxPositionNft.setConfigManager(address(strataxConfigManager));
    }

    function _configureDefaultAaveOneInch(
        StrataxConfigManager manager,
        StrataxPositionNft nft,
        address beacon,
        uint256 flashLoanFeeBps_,
        address caller
    ) internal {
        bytes32 lendingProtocolId = LENDING_AAVE_V3_ID;
        bytes32 swapProtocolId = SWAP_ONEINCH_V6_ID;

        vm.startPrank(caller);
        AaveOneInchPositionAdapter adapter = new AaveOneInchPositionAdapter(address(nft));
        manager.setProtocolPairConfig(lendingProtocolId, swapProtocolId, beacon, address(adapter));

        StrataxAaveLib.InitParams memory lendingConfig = StrataxAaveLib.InitParams({
            pool: AAVE_POOL,
            dataProvider: AAVE_PROTOCOL_DATA_PROVIDER,
            flashLoanFeeBps: flashLoanFeeBps_,
            defaultBorrowSafetyMargin: 9950,
            defaultMaxLeverageOffset: 75
        });

        Stratax1InchLib.Config memory swapConfig = Stratax1InchLib.Config({router: INCH_ROUTER});

        manager.setPlatformConfig(lendingProtocolId, swapProtocolId, abi.encode(lendingConfig), abi.encode(swapConfig));
        vm.stopPrank();
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
    function getSavedSwapData(address fromToken, address toToken, uint256 amount, address fromAddress)
        internal
        view
        returns (bytes memory swapData, uint256 expectedAmount)
    {
        string memory root = vm.projectRoot();
        string memory path =
            string.concat(root, "/test/fixtures/swap_data_block_", vm.toString(SAVED_DATA_BLOCK), ".json");
        string memory json = vm.readFile(path);

        // Preferred lookup key includes fromAddress because 1inch calldata can be address-bound.
        string memory fromSymbol = fromToken == WETH ? "WETH" : "USDC";
        string memory toSymbol = toToken == WETH ? "WETH" : "USDC";
        string memory keyWithAddress =
            string.concat(fromSymbol, "_to_", toSymbol, "_", vm.toString(amount), "_from_", vm.toString(fromAddress));

        // Try address-aware key first.
        try this.readSavedSwapDataByKey(json, keyWithAddress) returns (bytes memory foundSwapData) {
            return (foundSwapData, 0);
        } catch {}

        // No matching saved entry found for this scenario.
        return (bytes(""), 0);
    }

    /**
     * @notice Parse a specific swap entry from JSON fixtures.
     * @dev External wrapper is used so callers can try/catch parse failures.
     */
    function readSavedSwapDataByKey(string memory json, string memory key) external view returns (bytes memory) {
        bytes memory swapDataBytes = vm.parseJson(json, string.concat(".swaps.", key, ".swapData"));
        return abi.decode(swapDataBytes, (bytes));
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
            (swapData, expectedAmount) = getSavedSwapData(fromToken, toToken, amount, fromAddress);
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
