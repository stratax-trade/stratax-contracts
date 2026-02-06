// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Stratax} from "../../src/Stratax.sol";
import {StrataxPositionNft} from "../../src/StrataxPositionNft.sol";
import {StrataxOracle} from "../../src/StrataxOracle.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ConstantsEtMainnet} from "../Constants.sol";

/**
 * @title StrataxBeaconProxyTest
 * @notice Tests for Stratax contract using Beacon Proxy pattern
 */
contract StrataxBeaconProxyTest is Test, ConstantsEtMainnet {
    Stratax public strataxImplementation;
    UpgradeableBeacon public strataxBeacon;
    Stratax public stratax;
    StrataxOracle public strataxOracle;
    StrataxPositionNft public strataxPositionNft;
    StrataxPositionNft public strataxPositionNftImplementation;
    TransparentUpgradeableProxy public nftProxy;
    ProxyAdmin public proxyAdminContract;

    address public beaconOwner;
    address public proxyAdmin;
    uint256 public tokenId;

    function setUp() public {
        beaconOwner = address(0x1);
        proxyAdmin = address(0x2);

        // Mock price feed contracts to return 8 decimals
        vm.mockCall(USDC_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(WETH_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));

        // Mock Aave pool flash loan fee
        vm.mockCall(AAVE_POOL, abi.encodeWithSignature("FLASHLOAN_PREMIUM_TOTAL()"), abi.encode(uint128(9)));

        // Mock token decimals
        vm.mockCall(USDC, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.mockCall(WETH, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));

        // Deploy oracle
        strataxOracle = new StrataxOracle();
        strataxOracle.setPriceFeed(USDC, USDC_PRICE_FEED);
        strataxOracle.setPriceFeed(WETH, WETH_PRICE_FEED);

        // 1. Deploy Stratax implementation and beacon
        strataxImplementation = new Stratax();
        vm.prank(beaconOwner);
        strataxBeacon = new UpgradeableBeacon(address(strataxImplementation), beaconOwner);

        // 2. Deploy StrataxPositionNft implementation
        strataxPositionNftImplementation = new StrataxPositionNft();

        // 3. Deploy ProxyAdmin
        proxyAdminContract = new ProxyAdmin(address(this));

        // 4. Initialize StrataxPositionNft via TransparentUpgradeableProxy
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
        nftProxy = new TransparentUpgradeableProxy(
            address(strataxPositionNftImplementation), address(proxyAdminContract), nftInitData
        );
        strataxPositionNft = StrataxPositionNft(address(nftProxy));

        // 4. Mint position NFT which deploys Stratax proxy
        (uint256 _tokenId, address strataxProxy) = strataxPositionNft.mintPositionNft(proxyAdmin, USDC, WETH);
        tokenId = _tokenId;
        stratax = Stratax(strataxProxy);
    }

    function test_ProxyDeploymentAndInitialization() public view {
        // Verify initialization worked
        assertEq(address(stratax.aavePool()), AAVE_POOL, "Aave pool not set correctly");
        assertEq(address(stratax.aaveDataProvider()), AAVE_PROTOCOL_DATA_PROVIDER, "Data provider not set correctly");
        assertEq(address(stratax.oneInchRouter()), INCH_ROUTER, "1inch router not set correctly");
        assertEq(stratax.collateralToken(), USDC, "Collateral token not set correctly");
        assertEq(stratax.borrowToken(), WETH, "Borrow token not set correctly");
        assertEq(stratax.strataxOracle(), address(strataxOracle), "Oracle not set correctly");
        assertEq(strataxPositionNft.ownerOf(tokenId), proxyAdmin, "NFT owner should be proxyAdmin");
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

        // Upgrade beacon (only owner can do this)
        vm.prank(beaconOwner);
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
        vm.expectRevert();
        strataxBeacon.upgradeTo(address(newImplementation));

        // Owner can upgrade
        vm.prank(beaconOwner);
        strataxBeacon.upgradeTo(address(newImplementation));
    }

    function test_MultipleProxiesShareImplementation() public {
        // Mint second position NFT which deploys second Stratax proxy
        address secondOwner = address(0x3);
        (uint256 tokenId2, address strataxProxy2) = strataxPositionNft.mintPositionNft(secondOwner, USDC, WETH);
        Stratax stratax2 = Stratax(strataxProxy2);

        // Both proxies point to same implementation via beacon
        assertEq(strataxBeacon.implementation(), address(strataxImplementation), "Both should use same implementation");

        // Both proxies are initialized correctly but have different addresses
        assertEq(address(stratax2.aavePool()), AAVE_POOL, "Second proxy should be initialized");
        assertTrue(address(stratax) != address(stratax2), "Proxies should have different addresses");
        assertTrue(tokenId != tokenId2, "Token IDs should be different");

        // When we upgrade the beacon, both proxies upgrade
        Stratax newImplementation = new Stratax();
        vm.prank(beaconOwner);
        strataxBeacon.upgradeTo(address(newImplementation));

        // Both proxies now use new implementation
        assertEq(strataxBeacon.implementation(), address(newImplementation), "Beacon upgraded");
        assertEq(address(stratax.aavePool()), AAVE_POOL, "First proxy still works");
        assertEq(address(stratax2.aavePool()), AAVE_POOL, "Second proxy still works");
    }
}
