// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Stratax} from "../../src/Stratax.sol";
import {StrataxOracle} from "../../src/StrataxOracle.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ConstantsEtMainnet} from "../Constants.t.sol";

/**
 * @title StrataxBeaconProxyTest
 * @notice Tests for Stratax contract using Beacon Proxy pattern
 */
contract StrataxBeaconProxyTest is Test, ConstantsEtMainnet {
    Stratax public strataxImplementation;
    UpgradeableBeacon public beacon;
    BeaconProxy public proxy;
    Stratax public stratax;
    StrataxOracle public strataxOracle;

    address public beaconOwner;
    address public proxyAdmin;

    function setUp() public {
        beaconOwner = address(0x1);
        proxyAdmin = address(0x2);

        // Mock price feed contracts to return 8 decimals
        vm.mockCall(USDC_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(WETH_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));

        // Deploy oracle
        strataxOracle = new StrataxOracle();
        strataxOracle.setPriceFeed(USDC, USDC_PRICE_FEED);
        strataxOracle.setPriceFeed(WETH, WETH_PRICE_FEED);

        // 1. Deploy implementation
        strataxImplementation = new Stratax();

        // 2. Deploy beacon
        vm.prank(beaconOwner);
        beacon = new UpgradeableBeacon(address(strataxImplementation), beaconOwner);

        // 3. Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            Stratax.initialize.selector,
            AAVE_POOL,
            AAVE_PROTOCOL_DATA_PROVIDER,
            INCH_ROUTER,
            USDC,
            address(strataxOracle)
        );

        // 4. Deploy proxy
        proxy = new BeaconProxy(address(beacon), initData);

        // 5. Cast proxy to Stratax interface
        stratax = Stratax(address(proxy));

        // Transfer ownership to proxyAdmin
        stratax.transferOwnership(proxyAdmin);
    }

    function test_ProxyDeploymentAndInitialization() public view {
        // Verify initialization worked
        assertEq(address(stratax.aavePool()), AAVE_POOL, "Aave pool not set correctly");
        assertEq(address(stratax.aaveDataProvider()), AAVE_PROTOCOL_DATA_PROVIDER, "Data provider not set correctly");
        assertEq(address(stratax.oneInchRouter()), INCH_ROUTER, "1inch router not set correctly");
        assertEq(stratax.USDC(), USDC, "USDC not set correctly");
        assertEq(stratax.strataxOracle(), address(strataxOracle), "Oracle not set correctly");
        assertEq(stratax.owner(), proxyAdmin, "Owner not set correctly");
        assertEq(stratax.flashLoanFeeBps(), 9, "Flash loan fee not set correctly");
    }

    function test_CannotReinitialize() public {
        // Try to initialize again - should fail
        vm.expectRevert();
        stratax.initialize(AAVE_POOL, AAVE_PROTOCOL_DATA_PROVIDER, INCH_ROUTER, USDC, address(strataxOracle));
    }

    function test_BeaconPointsToCorrectImplementation() public view {
        assertEq(beacon.implementation(), address(strataxImplementation), "Beacon should point to implementation");
    }

    function test_ProxyUsesBeaconImplementation() public view {
        // The proxy should delegate to implementation via beacon
        assertEq(address(stratax), address(proxy), "Stratax should be the proxy address");
    }

    function test_UpgradeImplementation() public {
        // Deploy new implementation
        Stratax newImplementation = new Stratax();

        // Upgrade beacon (only owner can do this)
        vm.prank(beaconOwner);
        beacon.upgradeTo(address(newImplementation));

        // Verify beacon now points to new implementation
        assertEq(beacon.implementation(), address(newImplementation), "Beacon should point to new implementation");

        // Verify proxy still works and uses new implementation
        assertEq(address(stratax.aavePool()), AAVE_POOL, "Proxy should still work after upgrade");
    }

    function test_OnlyBeaconOwnerCanUpgrade() public {
        Stratax newImplementation = new Stratax();

        // Non-owner cannot upgrade
        vm.expectRevert();
        beacon.upgradeTo(address(newImplementation));

        // Owner can upgrade
        vm.prank(beaconOwner);
        beacon.upgradeTo(address(newImplementation));
    }

    function test_MultipleProxiesShareImplementation() public {
        // Deploy second proxy
        bytes memory initData = abi.encodeWithSelector(
            Stratax.initialize.selector,
            AAVE_POOL,
            AAVE_PROTOCOL_DATA_PROVIDER,
            INCH_ROUTER,
            USDC,
            address(strataxOracle)
        );

        BeaconProxy proxy2 = new BeaconProxy(address(beacon), initData);
        Stratax stratax2 = Stratax(address(proxy2));

        // Both proxies point to same implementation via beacon
        assertEq(beacon.implementation(), address(strataxImplementation), "Both should use same implementation");

        // Both proxies are initialized correctly but have different addresses
        assertEq(address(stratax2.aavePool()), AAVE_POOL, "Second proxy should be initialized");
        assertTrue(address(stratax) != address(stratax2), "Proxies should have different addresses");

        // When we upgrade the beacon, both proxies upgrade
        Stratax newImplementation = new Stratax();
        vm.prank(beaconOwner);
        beacon.upgradeTo(address(newImplementation));

        // Both proxies now use new implementation
        assertEq(beacon.implementation(), address(newImplementation), "Beacon upgraded");
        assertEq(address(stratax.aavePool()), AAVE_POOL, "First proxy still works");
        assertEq(address(stratax2.aavePool()), AAVE_POOL, "Second proxy still works");
    }

    function test_ProxyOwnershipIndependentFromBeacon() public {
        // Beacon owner controls upgrades
        assertEq(beacon.owner(), beaconOwner, "Beacon owned by beaconOwner");

        // Stratax owner controls contract operations
        assertEq(stratax.owner(), proxyAdmin, "Stratax owned by proxyAdmin");

        // proxyAdmin can call onlyOwner functions
        vm.prank(proxyAdmin);
        stratax.setFlashLoanFee(10);
        assertEq(stratax.flashLoanFeeBps(), 10, "ProxyAdmin can change fee");

        // beaconOwner cannot call onlyOwner functions
        vm.prank(beaconOwner);
        vm.expectRevert();
        stratax.setFlashLoanFee(20);
    }
}
