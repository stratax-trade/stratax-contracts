// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Stratax} from "../src/Stratax.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/**
 * @title UpgradeStrataxBeacon
 * @notice Script to upgrade Stratax implementation via Beacon
 * @dev This script:
 *      1. Deploys a new Stratax implementation
 *      2. Updates the beacon to point to the new implementation
 *      3. All proxies using this beacon will automatically use the new implementation
 */
contract UpgradeStrataxBeacon is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address beaconAddress = vm.envAddress("BEACON_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new implementation
        Stratax newImplementation = new Stratax();
        console.log("New Stratax Implementation deployed at:", address(newImplementation));

        // 2. Upgrade the beacon to point to new implementation
        UpgradeableBeacon beacon = UpgradeableBeacon(beaconAddress);
        beacon.upgradeTo(address(newImplementation));
        console.log("Beacon upgraded to new implementation");
        console.log("All proxies will now use the new implementation");

        vm.stopBroadcast();
    }
}
