// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Stratax} from "../../src/Stratax.sol";
import {StrataxOracle} from "../../src/StrataxOracle.sol";
import {ConstantsEtMainnet} from "../Constants.t.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

contract StrataxUnitTest is Test, ConstantsEtMainnet {
    Stratax public stratax;
    Stratax public strataxImplementation;
    UpgradeableBeacon public beacon;
    BeaconProxy public proxy;
    StrataxOracle public strataxOracle;
    address public ownerTrader;

    function setUp() public {
        ownerTrader = address(0x123);

        // Mock price feed contracts to return 8 decimals
        vm.mockCall(USDC_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(WETH_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));

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

    function test_ContractDeployment() public view {
        assertEq(address(stratax.aavePool()), AAVE_POOL, "AAVE Pool address mismatch");
        assertEq(address(stratax.oneInchRouter()), INCH_ROUTER, "1inch Router address mismatch");
        assertEq(stratax.USDC(), USDC, "USDC address mismatch");
        assertEq(stratax.owner(), ownerTrader, "Owner should be ownerTrader");
    }

    function test_ConstantsAreSet() public pure {
        assertTrue(AAVE_POOL != address(0), "AAVE Pool address is zero");
        assertTrue(USDC != address(0), "USDC address is zero");
        assertTrue(INCH_ROUTER != address(0), "1inch Router address is zero");
    }

    function test_BasisPointsConstant() public view {
        assertEq(stratax.FLASHLOAN_FEE_PREC(), 10000, "FLASHLOAN_FEE_PREC should be 10000");
    }

    function test_OwnerCanSetFlashLoanFee() public {
        vm.prank(ownerTrader);
        stratax.setFlashLoanFee(9);
        assertEq(stratax.flashLoanFeeBps(), 9, "Flash loan fee not set correctly");
    }

    function test_BeaconProxySetup() public view {
        assertEq(beacon.implementation(), address(strataxImplementation), "Beacon should point to implementation");
        assertEq(address(stratax), address(proxy), "Stratax should be the proxy address");
    }

    function test_CannotReinitialize() public {
        vm.expectRevert();
        stratax.initialize(AAVE_POOL, AAVE_PROTOCOL_DATA_PROVIDER, INCH_ROUTER, USDC, address(strataxOracle));
    }
}
