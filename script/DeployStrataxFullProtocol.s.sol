// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPool} from "../src/interfaces/external/IPool.sol";

import {StrataxOracle} from "../src/core/StrataxOracle.sol";
import {FeeCollector} from "../src/core/FeeCollector.sol";
import {StrataxPositionNft} from "../src/core/StrataxPositionNft.sol";
import {StrataxConfigManager} from "../src/core/StrataxConfigManager.sol";
import {StrataxProtocolBeacon} from "../src/core/StrataxProtocolBeacon.sol";

import {AaveOneInchPositionAdapter} from "../src/core/adapters/AaveOneInchPositionAdapter.sol";
import {AaveUniswapPositionAdapter} from "../src/core/adapters/AaveUniswapPositionAdapter.sol";
import {FluidUniswapPositionAdapter} from "../src/core/adapters/FluidUniswapPositionAdapter.sol";
import {OneInchExecutor} from "../src/core/executors/OneInchExecutor.sol";
import {UniswapV3Executor} from "../src/core/executors/UniswapV3Executor.sol";

import {Stratax_Aave_1Inch} from "../src/core/position-types/Stratax_Aave_1Inch.sol";
import {Stratax_Aave_Uniswap} from "../src/core/position-types/Stratax_Aave_Uniswap.sol";
import {Stratax_Fluid_Uniswap} from "../src/core/position-types/Stratax_Fluid_Uniswap.sol";

import {StrataxAavePositionInitConstants} from "../src/libraries/constants/StrataxAavePositionInitConstants.sol";
import {Stratax1InchConstants} from "../src/libraries/constants/Stratax1InchConstants.sol";
import {StrataxUniswapConstants} from "../src/libraries/constants/StrataxUniswapConstants.sol";
import {StrataxFluidConstants} from "../src/libraries/constants/StrataxFluidConstants.sol";

import {StrataxAaveLib} from "../src/libraries/lending/StrataxAaveLib.sol";
import {Stratax1InchLib} from "../src/libraries/swapping/Stratax1InchLib.sol";
import {StrataxUniswapLib} from "../src/libraries/swapping/StrataxUniswapLib.sol";
import {StrataxFluidLib} from "../src/libraries/lending/StrataxFluidLib.sol";

import {ConstantsEtMainnet} from "../test/Constants.sol";

contract DeployStrataxFullProtocol is Script, ConstantsEtMainnet {
    bytes32 internal constant LENDING_AAVE_V3_ID = keccak256("LENDING:AAVE_V3");
    bytes32 internal constant LENDING_FLUID_V1_ID = keccak256("LENDING:FLUID_V1");
    bytes32 internal constant SWAP_ONEINCH_V6_ID = keccak256("SWAP:ONEINCH_V6");
    bytes32 internal constant SWAP_UNISWAP_V3_ID = keccak256("SWAP:UNISWAP_V3");

    uint256 public constant DEFAULT_STRATAX_FEE_BPS = 50;
    string public constant DEFAULT_NFT_URI = "https://api.stratax.io/nft/metadata/";

    struct DeployedContracts {
        address strataxOracleProxy;
        address feeCollectorProxy;
        address strataxPositionNftProxy;
        address configManagerProxy;
        address aaveOneInchBeacon;
        address aaveUniswapBeacon;
        address fluidUniswapBeacon;
        address aaveOneInchAdapter;
        address aaveUniswapAdapter;
        address fluidUniswapAdapter;
    }

    // forge script script/DeployStrataxFullProtocol.s.sol --rpc-url https://eth-mainnet.g.alchemy.com/v2/UwNbcyrrjvQ0Y9brmLxvnoB44PovhKX4
    // https://eth-mainnet.g.alchemy.com/v2/UwNbcyrrjvQ0Y9brmLxvnoB44PovhKX4
    function run() external returns (DeployedContracts memory deployed) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying Full Stratax Protocol ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        deployed.strataxOracleProxy = _deployOracle(deployer);
        deployed.feeCollectorProxy = _deployFeeCollector(deployer);

        (deployed.strataxPositionNftProxy, deployed.configManagerProxy) =
            _deployPositionNftAndConfigManager(deployer, deployed.strataxOracleProxy, deployed.feeCollectorProxy);

        FeeCollector(deployed.feeCollectorProxy).setStrataxPositionNft(deployed.strataxPositionNftProxy);

        (
            deployed.aaveOneInchBeacon,
            deployed.aaveOneInchAdapter,
            deployed.aaveUniswapBeacon,
            deployed.aaveUniswapAdapter,
            deployed.fluidUniswapBeacon,
            deployed.fluidUniswapAdapter
        ) = _deployProtocolBeaconsAndAdapters(deployer, deployed.strataxPositionNftProxy);

        _configureProtocolPairsAndDefaults(
            deployed.strataxPositionNftProxy,
            deployed.configManagerProxy,
            deployed.aaveOneInchBeacon,
            deployed.aaveOneInchAdapter,
            deployed.aaveUniswapBeacon,
            deployed.aaveUniswapAdapter,
            deployed.fluidUniswapBeacon,
            deployed.fluidUniswapAdapter
        );

        vm.stopBroadcast();

        _logSummary(deployed);
        return deployed;
    }

    function _deployOracle(address owner) internal returns (address proxy) {
        StrataxOracle implementation = new StrataxOracle();
        bytes memory initData = abi.encodeWithSelector(StrataxOracle.initialize.selector, owner);
        proxy = address(new ERC1967Proxy(address(implementation), initData));

        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = WETH;

        address[] memory feeds = new address[](2);
        feeds[0] = USDC_PRICE_FEED;
        feeds[1] = WETH_PRICE_FEED;

        StrataxOracle(proxy).setPriceFeeds(tokens, feeds);

        console.log("  - StrataxOracle Impl:", address(implementation));
        console.log("  - StrataxOracle Proxy:", proxy);
    }

    function _deployFeeCollector(address owner) internal returns (address proxy) {
        FeeCollector implementation = new FeeCollector();
        // Initialize with a temporary placeholder; actual PositionNFT is set after it is deployed.
        bytes memory initData =
            abi.encodeWithSelector(FeeCollector.initialize.selector, owner, owner, DEFAULT_STRATAX_FEE_BPS);
        proxy = address(new ERC1967Proxy(address(implementation), initData));

        console.log("  - FeeCollector Impl:", address(implementation));
        console.log("  - FeeCollector Proxy:", proxy);
    }

    function _deployPositionNftAndConfigManager(address owner, address oracle, address feeCollector)
        internal
        returns (address nftProxy, address configManagerProxy)
    {
        // Temporary config manager so NFT initialization passes; replaced immediately after real manager deployment.
        StrataxConfigManager tempConfigManagerImpl = new StrataxConfigManager();
        bytes memory tempManagerInit = abi.encodeWithSelector(StrataxConfigManager.initialize.selector, owner, owner);
        address tempConfigManagerProxy = address(new ERC1967Proxy(address(tempConfigManagerImpl), tempManagerInit));

        StrataxPositionNft nftImpl = new StrataxPositionNft();
        StrataxPositionNft.StrataxPositionNftInitParams memory initParams =
            StrataxPositionNft.StrataxPositionNftInitParams({
                strataxOracle: oracle,
                feeCollector: feeCollector,
                configManager: tempConfigManagerProxy,
                owner: owner,
                uri: DEFAULT_NFT_URI
            });

        bytes memory nftInitData = abi.encodeWithSelector(StrataxPositionNft.initialize.selector, initParams);
        nftProxy = address(new ERC1967Proxy(address(nftImpl), nftInitData));

        StrataxConfigManager managerImpl = new StrataxConfigManager();
        bytes memory managerInitData = abi.encodeWithSelector(StrataxConfigManager.initialize.selector, owner, nftProxy);
        configManagerProxy = address(new ERC1967Proxy(address(managerImpl), managerInitData));

        StrataxPositionNft(nftProxy).setConfigManager(configManagerProxy);

        console.log("  - PositionNFT Impl:", address(nftImpl));
        console.log("  - PositionNFT Proxy:", nftProxy);
        console.log("  - ConfigManager Impl:", address(managerImpl));
        console.log("  - ConfigManager Proxy:", configManagerProxy);
    }

    function _deployProtocolBeaconsAndAdapters(address owner, address positionNftProxy)
        internal
        returns (
            address aaveOneInchBeacon,
            address aaveOneInchAdapter,
            address aaveUniswapBeacon,
            address aaveUniswapAdapter,
            address fluidUniswapBeacon,
            address fluidUniswapAdapter
        )
    {
        OneInchExecutor oneInchExecutor = new OneInchExecutor();
        UniswapV3Executor uniswapExecutor = new UniswapV3Executor();

        Stratax_Aave_1Inch aaveOneInchImpl = new Stratax_Aave_1Inch();
        aaveOneInchBeacon =
            address(new StrataxProtocolBeacon(address(aaveOneInchImpl), owner, LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID));
        aaveOneInchAdapter = address(new AaveOneInchPositionAdapter(positionNftProxy, oneInchExecutor));

        Stratax_Aave_Uniswap aaveUniswapImpl = new Stratax_Aave_Uniswap();
        aaveUniswapBeacon =
            address(new StrataxProtocolBeacon(address(aaveUniswapImpl), owner, LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID));
        aaveUniswapAdapter = address(new AaveUniswapPositionAdapter(positionNftProxy, uniswapExecutor));

        Stratax_Fluid_Uniswap fluidUniswapImpl = new Stratax_Fluid_Uniswap();
        fluidUniswapBeacon = address(
            new StrataxProtocolBeacon(address(fluidUniswapImpl), owner, LENDING_FLUID_V1_ID, SWAP_UNISWAP_V3_ID)
        );
        fluidUniswapAdapter = address(new FluidUniswapPositionAdapter(positionNftProxy));

        console.log("  - Aave+1Inch Beacon:", aaveOneInchBeacon);
        console.log("  - Aave+1Inch Adapter:", aaveOneInchAdapter);
        console.log("  - Aave+Uniswap Beacon:", aaveUniswapBeacon);
        console.log("  - Aave+Uniswap Adapter:", aaveUniswapAdapter);
        console.log("  - Fluid+Uniswap Beacon:", fluidUniswapBeacon);
        console.log("  - Fluid+Uniswap Adapter:", fluidUniswapAdapter);
    }

    function _configureProtocolPairsAndDefaults(
        address positionNftProxy,
        address configManagerProxy,
        address aaveOneInchBeacon,
        address aaveOneInchAdapter,
        address aaveUniswapBeacon,
        address aaveUniswapAdapter,
        address fluidUniswapBeacon,
        address fluidUniswapAdapter
    ) internal {
        positionNftProxy;

        StrataxConfigManager manager = StrataxConfigManager(configManagerProxy);

        manager.setProtocolPairConfig(LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID, aaveOneInchBeacon, aaveOneInchAdapter);
        manager.setProtocolPairConfig(LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID, aaveUniswapBeacon, aaveUniswapAdapter);
        manager.setProtocolPairConfig(LENDING_FLUID_V1_ID, SWAP_UNISWAP_V3_ID, fluidUniswapBeacon, fluidUniswapAdapter);

        StrataxAaveLib.InitParams memory aaveConfig = StrataxAavePositionInitConstants.ethereumConfigParams(
            IPool(StrataxAavePositionInitConstants.ETHEREUM_AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL()
        );
        Stratax1InchLib.Config memory oneInchConfig = Stratax1InchConstants.ethereumConfigParams();
        StrataxUniswapLib.Config memory uniswapConfig = StrataxUniswapConstants.ethereumConfigParams();
        StrataxFluidLib.InitParams memory fluidConfig = StrataxFluidConstants.ethereumConfigParams();

        manager.setPlatformConfig(
            LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID, abi.encode(aaveConfig), abi.encode(oneInchConfig)
        );

        manager.setPlatformConfig(
            LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID, abi.encode(aaveConfig), abi.encode(uniswapConfig)
        );

        manager.setPlatformConfig(
            LENDING_FLUID_V1_ID, SWAP_UNISWAP_V3_ID, abi.encode(fluidConfig), abi.encode(uniswapConfig)
        );
    }

    function _logSummary(DeployedContracts memory deployed) internal pure {
        console.log("\n=== Deployment Summary ===");
        console.log("StrataxOracle Proxy:", deployed.strataxOracleProxy);
        console.log("FeeCollector Proxy:", deployed.feeCollectorProxy);
        console.log("StrataxPositionNft Proxy:", deployed.strataxPositionNftProxy);
        console.log("StrataxConfigManager Proxy:", deployed.configManagerProxy);

        console.log("\n=== Protocol Pair Beacons ===");
        console.log("Aave+1Inch Beacon:", deployed.aaveOneInchBeacon);
        console.log("Aave+Uniswap Beacon:", deployed.aaveUniswapBeacon);
        console.log("Fluid+Uniswap Beacon:", deployed.fluidUniswapBeacon);

        console.log("\n=== Adapters ===");
        console.log("Aave+1Inch Adapter:", deployed.aaveOneInchAdapter);
        console.log("Aave+Uniswap Adapter:", deployed.aaveUniswapAdapter);
        console.log("Fluid+Uniswap Adapter:", deployed.fluidUniswapAdapter);

        console.log("\n=== Token/Feed Inputs (from test constants) ===");
        console.log("USDC:", USDC);
        console.log("WETH:", WETH);
        console.log("USDC_PRICE_FEED:", USDC_PRICE_FEED);
        console.log("WETH_PRICE_FEED:", WETH_PRICE_FEED);
    }
}
