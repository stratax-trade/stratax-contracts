// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseStrataxTest} from "./BaseStrataxTest.sol";
import {Stratax} from "../../src/core/Stratax.sol";
import {StrataxPositionNft} from "../../src/core/StrataxPositionNft.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/**
 * @title StrataxBeaconProxyTest
 * @notice Tests for Stratax contract beacon proxy upgrade functionality
 * @dev Focuses on testing beacon upgrades while using base test infrastructure
 */
contract StrataxBeaconProxyTest is BaseStrataxTest {
    /**
     * @notice Sets up the test environment using base setup
     */
    function setUp() public override {
        super.setUp();
    }

    function test_ProxyDeploymentAndInitialization() public view {
        // Verify initialization worked (using base setup)
        assertEq(address(stratax.aavePool()), AAVE_POOL, "Aave pool not set correctly");
        assertEq(address(stratax.aaveDataProvider()), AAVE_PROTOCOL_DATA_PROVIDER, "Data provider not set correctly");
        assertEq(address(stratax.oneInchRouter()), INCH_ROUTER, "1inch router not set correctly");
        assertEq(stratax.collateralToken(), USDC, "Collateral token not set correctly");
        assertEq(stratax.borrowToken(), WETH, "Borrow token not set correctly");
        assertEq(stratax.strataxOracle(), address(strataxOracle), "Oracle not set correctly");
        assertEq(strataxPositionNft.ownerOf(tokenId), ownerTrader, "NFT owner should be ownerTrader");
        assertEq(stratax.flashLoanFeeBps(), 9, "Flash loan fee not set correctly");
    }

    function test_BeaconPointsToCorrectImplementation() public view {
        assertEq(
            strataxBeacon.implementation(), address(strataxImplementation), "Beacon should point to implementation"
        );
    }

    function test_UpgradeImplementation() public {
        // Deploy new implementation
        Stratax newImplementation = new Stratax();

        // Upgrade beacon (only admin can do this - admin is beacon owner from base test)
        vm.prank(admin);
        strataxBeacon.upgradeTo(address(newImplementation));

        // Verify beacon now points to new implementation
        assertEq(
            strataxBeacon.implementation(), address(newImplementation), "Beacon should point to new implementation"
        );

        // Verify proxy still works and uses new implementation
        assertEq(address(stratax.aavePool()), AAVE_POOL, "Proxy should still work after upgrade");
    }

    function test_OnlyBeaconOwnerCanUpgrade() public {
        Stratax newImplementation = new Stratax();

        // Non-owner cannot upgrade
        vm.prank(ownerTrader);
        vm.expectRevert();
        strataxBeacon.upgradeTo(address(newImplementation));

        // Owner (admin) can upgrade
        vm.prank(admin);
        strataxBeacon.upgradeTo(address(newImplementation));

        assertEq(strataxBeacon.implementation(), address(newImplementation), "Beacon should be upgraded");
    }

    function test_MultipleProxiesShareImplementation() public {
        // Mint second position NFT which deploys second Stratax proxy
        address secondOwner = address(0x456);
        StrataxPositionNft.InitPositionParams memory emptyParams;
        (uint256 tokenId2, address strataxProxy2) =
            strataxPositionNft.mintPositionNft(secondOwner, USDC, WETH, false, emptyParams);
        Stratax stratax2 = Stratax(strataxProxy2);

        // Both proxies point to same implementation via beacon
        assertEq(strataxBeacon.implementation(), address(strataxImplementation), "Both should use same implementation");

        // Both proxies are initialized correctly but have different addresses
        assertEq(address(stratax2.aavePool()), AAVE_POOL, "Second proxy should be initialized");
        assertTrue(address(stratax) != address(stratax2), "Proxies should have different addresses");
        assertTrue(tokenId != tokenId2, "Token IDs should be different");

        // When we upgrade the beacon, both proxies upgrade
        Stratax newImplementation = new Stratax();
        vm.prank(admin);
        strataxBeacon.upgradeTo(address(newImplementation));

        // Both proxies now use new implementation
        assertEq(strataxBeacon.implementation(), address(newImplementation), "Beacon upgraded");
        assertEq(address(stratax.aavePool()), AAVE_POOL, "First proxy still works");
        assertEq(address(stratax2.aavePool()), AAVE_POOL, "Second proxy still works");
    }
}
