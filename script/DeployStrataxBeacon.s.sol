// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Stratax} from "../src/Stratax.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

/**
 * @title DeployStrataxBeacon
 * @notice Deployment script for Stratax contract using Beacon Proxy pattern
 * @dev This script deploys:
 *      1. Stratax implementation contract
 *      2. UpgradeableBeacon pointing to the implementation
 *      3. BeaconProxy that delegates to the implementation via the beacon
 */
contract DeployStrataxBeacon is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address aavePool = vm.envAddress("AAVE_POOL");
        address aaveDataProvider = vm.envAddress("AAVE_DATA_PROVIDER");
        address oneInchRouter = vm.envAddress("ONE_INCH_ROUTER");
        address usdc = vm.envAddress("USDC");
        address strataxOracle = vm.envAddress("STRATAX_ORACLE");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy the implementation contract
        Stratax implementation = new Stratax();
        console.log("Stratax Implementation deployed at:", address(implementation));

        // 2. Deploy the beacon pointing to the implementation
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementation), msg.sender);
        console.log("UpgradeableBeacon deployed at:", address(beacon));

        // 3. Encode the initialize function call
        bytes memory initData = abi.encodeWithSelector(
            Stratax.initialize.selector, aavePool, aaveDataProvider, oneInchRouter, usdc, strataxOracle
        );

        // 4. Deploy the beacon proxy
        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        console.log("BeaconProxy deployed at:", address(proxy));
        console.log("Use this address to interact with Stratax:", address(proxy));

        vm.stopBroadcast();
    }
}
