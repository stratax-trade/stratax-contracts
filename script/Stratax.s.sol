// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Stratax} from "../src/Stratax.sol";

contract StrataxScript is Script {
    Stratax public stratax;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        //TODO add deployment code

        vm.stopBroadcast();
    }
}
