// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Stratax_Aave_1Inch as Stratax} from "../src/core/position-types/Stratax_Aave_1Inch.sol";
import {StrataxOracle} from "../src/core/StrataxOracle.sol";
import {FeeCollector} from "../src/core/FeeCollector.sol";
import {StrataxPositionNft} from "../src/core/StrataxPositionNft.sol";
import {StrataxConfigManager} from "../src/core/StrataxConfigManager.sol";
import {StrataxProtocolBeacon} from "../src/core/StrataxProtocolBeacon.sol";
import {AaveOneInchPositionAdapter} from "../src/core/adapters/AaveOneInchPositionAdapter.sol";
import {StrataxAaveLib} from "../src/libraries/lending/StrataxAaveLib.sol";
import {Stratax1InchLib} from "../src/libraries/swapping/Stratax1InchLib.sol";
import {StrataxAavePositionInitConstants} from "../src/libraries/constants/StrataxAavePositionInitConstants.sol";
import {Stratax1InchConstants} from "../src/libraries/constants/Stratax1InchConstants.sol";
import {ConstantsEtMainnet} from "../test/Constants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPool} from "../src/interfaces/external/IPool.sol";

/**
 * @title DeployStrataxSystem
 * @notice Comprehensive deployment script for the entire Stratax system
 * @dev This script deploys:
 *      1. StrataxOracle as UUPS Proxy
 *      2. FeeCollector as UUPS Proxy
 *      3. StrataxPositionNft as UUPS Proxy
 *      4. Stratax implementation with UpgradeableBeacon
 */
contract DeployStrataxSystem is Script, ConstantsEtMainnet {
    bytes32 internal constant LENDING_AAVE_V3_ID = keccak256("LENDING:AAVE_V3");
    bytes32 internal constant SWAP_ONEINCH_V6_ID = keccak256("SWAP:ONEINCH_V6");

    // Default configuration values
    uint256 public constant DEFAULT_STRATAX_FEE = 50; // 0.5% (50/10000)
    uint256 public constant DEFAULT_BORROW_SAFETY_MARGIN = 9900; // 99%
    string public constant DEFAULT_NFT_URI = "https://api.stratax.io/nft/metadata/";

    struct DeployedContracts {
        address strataxOracleProxy;
        address feeCollectorProxy;
        address strataxPositionNftProxy;
        address configManager;
        address strataxBeacon;
        address strataxImplementation;
    }

    /* Deploying conrtacts with tednerly and verifying
       	forge script script/DeployStrataxSystem.s.sol \
    --slow \
     --verify \
     --verifier custom \
     --verifier-url https://virtual.mainnet.us-east.rpc.tenderly.co/59b98c14-e3f1-4c22-8cdb-d62f00605007/verify \
     --rpc-url https://virtual.mainnet.us-east.rpc.tenderly.co/59b98c14-e3f1-4c22-8cdb-d62f00605007 \
     --broadcast



       */

    // anvil --fork-url https://eth-mainnet.g.alchemy.com/v2/UwNbcyrrjvQ0Y9brmLxvnoB44PovhKX4
    // forge script script/DeployStrataxSystem.s.sol --rpc-url http://localhost:8545 --broadcast
    //
    // tenderly deploy
    // forge script script/DeployStrataxSystem.s.sol --slow --rpc-url https://virtual.mainnet.us-east.rpc.tenderly.co/59b98c14-e3f1-4c22-8cdb-d62f00605007 --broadcast

    // forge script script/DeployStrataxSystem.s.sol --rpc-url https://eth-mainnet.g.alchemy.com/v2/UwNbcyrrjvQ0Y9brmLxvnoB44PovhKX4
    /**
     * @notice Main deployment function
     * @dev Execute with: forge script script/DeployStrataxSystem.s.sol --rpc-url <RPC_URL> --broadcast
     */
    function run() external returns (DeployedContracts memory deployed) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying Stratax System ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        vm.deal(deployer, 100 ether);

        // 1. Deploy StrataxOracle as UUPS
        console.log("\n1. Deploying StrataxOracle...");
        deployed.strataxOracleProxy = deployStrataxOracle(deployer);

        // 2. Deploy FeeCollector as UUPS
        console.log("\n2. Deploying FeeCollector...");
        deployed.feeCollectorProxy = deployFeeCollector(deployer);

        // 3. Deploy Stratax Beacon
        console.log("\n3. Deploying Stratax Beacon...");
        (deployed.strataxBeacon, deployed.strataxImplementation) = deployStrataxBeacon(deployer);

        // 4. Deploy StrataxPositionNft as UUPS
        console.log("\n4. Deploying StrataxPositionNft...");
        deployed.strataxPositionNftProxy = deployStrataxPositionNft(
            deployer, deployed.strataxBeacon, deployed.strataxOracleProxy, deployed.feeCollectorProxy
        );

        // 5. Deploy StrataxConfigManager and hand over NFT config ownership
        console.log("\n5. Deploying StrataxConfigManager...");
        deployed.configManager = deployConfigManager(deployer, deployed.strataxPositionNftProxy);
        configureDefaultAaveOneInchPath(
            deployed.strataxPositionNftProxy, deployed.configManager, deployed.strataxBeacon
        );

        vm.stopBroadcast();

        // Log deployment summary
        logDeploymentSummary(deployed);

        return deployed;
    }

    /**
     * @notice Deploys StrataxOracle as a UUPS proxy
     * @param owner The address that will own the contract
     * @return proxy The address of the UUPS proxy
     */
    function deployStrataxOracle(address owner) internal returns (address proxy) {
        // Deploy implementation
        StrataxOracle implementation = new StrataxOracle();
        console.log("  - StrataxOracle Implementation:", address(implementation));

        // Encode initialize call
        bytes memory initData = abi.encodeWithSelector(StrataxOracle.initialize.selector, owner);

        // Deploy UUPS proxy
        ERC1967Proxy uupsProxy = new ERC1967Proxy(address(implementation), initData);
        proxy = address(uupsProxy);
        console.log("  - StrataxOracle Proxy:", proxy);

        // Setup initial price feeds
        StrataxOracle oracle = StrataxOracle(proxy);

        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = WETH;

        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = USDC_PRICE_FEED;
        priceFeeds[1] = WETH_PRICE_FEED;

        oracle.setPriceFeeds(tokens, priceFeeds);
        console.log("  - Price feeds configured for USDC and WETH");
    }

    /**
     * @notice Deploys FeeCollector as a UUPS proxy
     * @param owner The address that will own the contract
     * @return proxy The address of the UUPS proxy
     */
    function deployFeeCollector(address owner) internal returns (address proxy) {
        // Deploy implementation
        FeeCollector implementation = new FeeCollector();
        console.log("  - FeeCollector Implementation:", address(implementation));

        // Encode initialize call
        bytes memory initData = abi.encodeWithSelector(FeeCollector.initialize.selector, owner, DEFAULT_STRATAX_FEE);

        // Deploy UUPS proxy
        ERC1967Proxy uupsProxy = new ERC1967Proxy(address(implementation), initData);
        proxy = address(uupsProxy);
        console.log("  - FeeCollector Proxy:", proxy);
        console.log("  - Default fee set to:", DEFAULT_STRATAX_FEE, "(0.5%)");
    }

    /**
     * @notice Deploys Stratax implementation and Beacon
     * @param owner The address that will own the beacon
     * @return beacon The address of the UpgradeableBeacon
     * @return implementation The address of the Stratax implementation
     */
    function deployStrataxBeacon(address owner) internal returns (address beacon, address implementation) {
        // Deploy implementation
        Stratax strataxImpl = new Stratax();
        implementation = address(strataxImpl);
        console.log("  - Stratax Implementation:", implementation);

        // Deploy beacon
        StrataxProtocolBeacon strataxBeacon =
            new StrataxProtocolBeacon(implementation, owner, LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID);
        beacon = address(strataxBeacon);
        console.log("  - Stratax Beacon:", beacon);
    }

    /**
     * @notice Deploys StrataxPositionNft as a UUPS proxy
     * @param owner The address that will own the contract
     * @param strataxBeacon The address of the Stratax beacon
     * @param strataxOracle The address of the StrataxOracle proxy
     * @param feeCollector The address of the FeeCollector proxy
     * @return proxy The address of the UUPS proxy
     */
    function deployStrataxPositionNft(address owner, address strataxBeacon, address strataxOracle, address feeCollector)
        internal
        returns (address proxy)
    {
        // Configuration through StrataxConfigManager uses the beacon after deployment.
        strataxBeacon;

        // Deploy implementation
        StrataxPositionNft implementation = new StrataxPositionNft();
        console.log("  - StrataxPositionNft Implementation:", address(implementation));

        // Create initialization params
        StrataxPositionNft.StrataxPositionNftInitParams memory initParams =
            StrataxPositionNft.StrataxPositionNftInitParams({
                strataxOracle: strataxOracle,
                feeCollector: feeCollector,
                configManager: address(this),
                owner: owner,
                uri: DEFAULT_NFT_URI
            });

        // Encode initialize call
        bytes memory initData = abi.encodeWithSelector(StrataxPositionNft.initialize.selector, initParams);

        // Deploy UUPS proxy
        ERC1967Proxy uupsProxy = new ERC1967Proxy(address(implementation), initData);
        proxy = address(uupsProxy);
        console.log("  - StrataxPositionNft Proxy:", proxy);
        console.log("  - Base URI:", DEFAULT_NFT_URI);
    }

    function deployConfigManager(address owner, address positionNft) internal returns (address manager) {
        StrataxConfigManager implementation = new StrataxConfigManager();
        bytes memory initData = abi.encodeWithSelector(StrataxConfigManager.initialize.selector, owner, positionNft);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        manager = address(proxy);
        console.log("  - StrataxConfigManager:", manager);
    }

    function configureDefaultAaveOneInchPath(
        address positionNftAddress,
        address configManagerAddress,
        address strataxBeacon
    ) internal {
        StrataxPositionNft positionNft = StrataxPositionNft(positionNftAddress);
        StrataxConfigManager configManager = StrataxConfigManager(configManagerAddress);

        positionNft.setConfigManager(configManagerAddress);

        bytes32 lendingProtocolId = LENDING_AAVE_V3_ID;
        bytes32 swapProtocolId = SWAP_ONEINCH_V6_ID;

        AaveOneInchPositionAdapter adapter = new AaveOneInchPositionAdapter(positionNftAddress);
        configManager.setProtocolPairConfig(lendingProtocolId, swapProtocolId, strataxBeacon, address(adapter));

        StrataxAaveLib.InitParams memory lendingDefaults = StrataxAavePositionInitConstants.ethereumConfigParams(
            IPool(StrataxAavePositionInitConstants.ETHEREUM_AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL()
        );
        Stratax1InchLib.Config memory swapDefaults = Stratax1InchConstants.ethereumConfigParams();

        bytes memory lendingData = abi.encode(lendingDefaults);
        bytes memory swapData = abi.encode(swapDefaults);
        configManager.setPlatformConfig(lendingProtocolId, swapProtocolId, lendingData, swapData);
    }

    /**
     * @notice Logs a summary of all deployed contracts
     * @param deployed Struct containing all deployed contract addresses
     */
    function logDeploymentSummary(DeployedContracts memory deployed) internal pure {
        console.log("\n=== Deployment Summary ===");
        console.log("StrataxOracle (UUPS):", deployed.strataxOracleProxy);
        console.log("FeeCollector (UUPS):", deployed.feeCollectorProxy);
        console.log("StrataxPositionNft (UUPS):", deployed.strataxPositionNftProxy);
        console.log("StrataxConfigManager:", deployed.configManager);
        console.log("Stratax Beacon:", deployed.strataxBeacon);
        console.log("Stratax Implementation:", deployed.strataxImplementation);
        console.log("\n=== Key Integrations ===");
        console.log("Aave Pool:", AAVE_POOL);
        console.log("Aave Data Provider:", AAVE_PROTOCOL_DATA_PROVIDER);
        console.log("1inch Router:", INCH_ROUTER);
        console.log("\n=== Configuration ===");
        console.log("USDC:", USDC);
        console.log("WETH:", WETH);
        console.log("USDC Price Feed:", USDC_PRICE_FEED);
        console.log("WETH Price Feed:", WETH_PRICE_FEED);
        console.log("\nDeployment complete!");
    }
}
