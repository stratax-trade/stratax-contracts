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
import {StrataxAavePositionInitConstants} from "../../src/libraries/constants/StrataxAavePositionInitConstants.sol";
import {Stratax1InchConstants} from "../../src/libraries/constants/Stratax1InchConstants.sol";
import {ConstantsEtMainnet} from "../Constants.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title BaseStrataxTest
 * @notice Base test contract with common setup logic for Stratax tests
 * @dev All Stratax test contracts should inherit from this base
 */
abstract contract BaseStrataxTest is Test, ConstantsEtMainnet {
    bytes32 internal constant LENDING_AAVE_V3_ID = keccak256("LENDING:AAVE_V3");
    bytes32 internal constant SWAP_ONEINCH_V6_ID = keccak256("SWAP:ONEINCH_V6");

    // Default configuration values (matching deployment script)
    uint256 public constant DEFAULT_STRATAX_FEE = 50; // 0.5% (50/10000)
    string public constant DEFAULT_NFT_URI = "https://api.stratax.io/nft/metadata/";

    // Core contracts
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

    // Test addresses
    address public ownerTrader;
    address public admin;
    uint256 public tokenId;

    // Mock addresses for Aave tokens
    address public mockATokenUSDC;
    address public mockStableDebtUSDC;
    address public mockVariableDebtUSDC;
    address public mockATokenWETH;
    address public mockStableDebtWETH;
    address public mockVariableDebtWETH;

    /**
     * @notice Base setUp function - can be overridden by child contracts
     * @dev Child contracts should call super.setUp() to maintain base setup
     */
    function setUp() public virtual {
        ownerTrader = address(0x123);
        admin = makeAddr("admin");

        // Setup basic mocks
        setupBasicMocks();

        // Deploy all contracts in dependency order
        deployStrataxOracle(admin);
        deployStrataxBeacon(admin);
        deployFeeCollector(admin, address(0)); // Pass address(0) for now, will be set when NFT is deployed
        deployStrataxPositionNft(admin);
        deployStrataxConfigManager(admin);

        _configureDefaultAaveOneInch(strataxConfigManager, strataxPositionNft, address(strataxBeacon), 9, admin);

        // Update FeeCollector with actual StrataxPositionNft address
        vm.prank(admin);
        feeCollector.setStrataxPositionNft(address(strataxPositionNft));

        // Setup Aave configuration mocks
        setupAaveConfigMocks();

        // Mint initial position NFT
        mintInitialPosition();
    }

    /*//////////////////////////////////////////////////////////////
                            MOCK SETUP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets up basic mocks for price feeds, tokens, and Aave pool
     */
    function setupBasicMocks() internal {
        // Mock price feed contracts to return 8 decimals
        vm.mockCall(USDC_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(WETH_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));

        // Mock Aave pool flash loan fee
        vm.mockCall(AAVE_POOL, abi.encodeWithSignature("FLASHLOAN_PREMIUM_TOTAL()"), abi.encode(uint128(9)));

        // Mock token decimals
        vm.mockCall(USDC, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.mockCall(WETH, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
    }

    /**
     * @notice Sets up Aave configuration mocks for USDC and WETH
     */
    function setupAaveConfigMocks() internal virtual {
        uint256 ltv = 8000; // 80% LTV

        // Mock Aave data provider to return LTV for USDC
        vm.mockCall(
            AAVE_PROTOCOL_DATA_PROVIDER,
            abi.encodeWithSignature("getReserveConfigurationData(address)", USDC),
            abi.encode(uint256(0), ltv, uint256(0), uint256(0), uint256(0), true, true, false, true, false)
        );

        // Mock Aave data provider to return configuration for WETH
        vm.mockCall(
            AAVE_PROTOCOL_DATA_PROVIDER,
            abi.encodeWithSignature("getReserveConfigurationData(address)", WETH),
            abi.encode(uint256(0), ltv, uint256(0), uint256(0), uint256(0), true, true, false, true, false)
        );
    }

    /**
     * @notice Sets up mock token addresses for Aave reserve tokens
     * @param strataxProxy The Stratax proxy address to mock balances for
     */
    function setupAaveTokenMocks(address strataxProxy) internal {
        // Setup USDC token mocks
        mockATokenUSDC = address(0x1001);
        mockStableDebtUSDC = address(0x1002);
        mockVariableDebtUSDC = address(0x1003);

        vm.mockCall(
            AAVE_PROTOCOL_DATA_PROVIDER,
            abi.encodeWithSignature("getReserveTokensAddresses(address)", USDC),
            abi.encode(mockATokenUSDC, mockStableDebtUSDC, mockVariableDebtUSDC)
        );
        vm.mockCall(mockATokenUSDC, abi.encodeWithSignature("balanceOf(address)", strataxProxy), abi.encode(0));

        // Setup WETH token mocks
        mockATokenWETH = address(0x2001);
        mockStableDebtWETH = address(0x2002);
        mockVariableDebtWETH = address(0x2003);

        vm.mockCall(
            AAVE_PROTOCOL_DATA_PROVIDER,
            abi.encodeWithSignature("getReserveTokensAddresses(address)", WETH),
            abi.encode(mockATokenWETH, mockStableDebtWETH, mockVariableDebtWETH)
        );
        vm.mockCall(mockVariableDebtWETH, abi.encodeWithSignature("balanceOf(address)", strataxProxy), abi.encode(0));
    }

    /**
     * @notice Mints the initial position NFT (can be overridden to skip)
     */
    function mintInitialPosition() internal virtual {
        (uint256 _tokenId, address strataxProxy) =
            strataxPositionNft.mintPosition(ownerTrader, USDC, WETH, LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID);
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

    /**
     * @notice Helper function to deploy a test StrataxPositionNft with custom fee collector
     * @param owner The address that will own the contract
     * @param customFeeCollector The custom fee collector address
     * @return testNft The deployed StrataxPositionNft
     */
    function deployTestStrataxPositionNft(address owner, address customFeeCollector)
        internal
        returns (StrataxPositionNft testNft)
    {
        // Deploy new implementation
        StrataxPositionNft testImplementation = new StrataxPositionNft();

        // Create initialization params
        StrataxPositionNft.StrataxPositionNftInitParams memory nftParams =
            StrataxPositionNft.StrataxPositionNftInitParams({
                strataxOracle: address(strataxOracle),
                feeCollector: customFeeCollector,
                configManager: address(this),
                owner: owner,
                uri: DEFAULT_NFT_URI
            });

        // Encode initialize call
        bytes memory nftInitData = abi.encodeWithSelector(StrataxPositionNft.initialize.selector, nftParams);

        // Deploy UUPS proxy
        ERC1967Proxy testProxy = new ERC1967Proxy(address(testImplementation), nftInitData);
        testNft = StrataxPositionNft(address(testProxy));

        StrataxConfigManager testConfigManager;
        {
            StrataxConfigManager implementation = new StrataxConfigManager();
            bytes memory initData =
                abi.encodeWithSelector(StrataxConfigManager.initialize.selector, owner, address(testNft));
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
            testConfigManager = StrataxConfigManager(address(proxy));
        }
        vm.prank(owner);
        testNft.setConfigManager(address(testConfigManager));

        _configureDefaultAaveOneInch(testConfigManager, testNft, address(strataxBeacon), 9, owner);

        // Update fee collector with this NFT contract if it's not the same as the main one
        if (customFeeCollector != address(feeCollector)) {
            vm.prank(owner);
            FeeCollector(customFeeCollector).setStrataxPositionNft(address(testNft));
        }
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

        bytes memory lendingData = abi.encode(StrataxAavePositionInitConstants.ethereumConfigParams(flashLoanFeeBps_));
        bytes memory swapData = abi.encode(Stratax1InchConstants.ethereumConfigParams());

        manager.setPlatformConfig(lendingProtocolId, swapProtocolId, lendingData, swapData);
        vm.stopPrank();
    }
}
