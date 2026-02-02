// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Stratax} from "../src/Stratax.sol";
import {StrataxOracle} from "../src/StrataxOracle.sol";
import {ConstantsEtMainnet} from "../test/Constants.sol";
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
contract DeployStrataxBeacon is Script, ConstantsEtMainnet {
    // forge script script/DeployStrataxBeacon.s.sol --rpc-url http://127.0.0.1:8545
    function run() external {
        // Anvil: http://127.0.0.1:8545
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        StrataxOracle strataxOracle = new StrataxOracle();

        // 1. Deploy the implementation contract
        Stratax implementation = new Stratax();
        console.log("Stratax Implementation deployed at:", address(implementation));

        // 2. Deploy the beacon pointing to the implementation
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementation), msg.sender);
        console.log("UpgradeableBeacon deployed at:", address(beacon));

        // 3. Encode the initialize function call
        bytes memory initData = abi.encodeWithSelector(
            Stratax.initialize.selector,
            AAVE_POOL,
            AAVE_PROTOCOL_DATA_PROVIDER,
            INCH_ROUTER,
            USDC,
            address(strataxOracle)
        );

        // 4. Deploy the beacon proxy
        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        console.log("BeaconProxy deployed at:", address(proxy));
        console.log("Use this address to interact with Stratax:", address(proxy));

        vm.stopBroadcast();
    }
}
