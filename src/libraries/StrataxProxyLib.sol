// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/**
 * @title StrataxProxyLib
 * @notice Shared utilities for deploying and predicting BeaconProxy addresses via CREATE2.
 * @dev Used by all combined deployment libraries to avoid duplicating proxy deployment logic.
 */
library StrataxProxyLib {
    /// @notice Deploys a BeaconProxy via CREATE2.
    function deploy(address beacon, bytes32 salt, bytes memory initData) internal returns (address proxy) {
        proxy = address(new BeaconProxy{salt: salt}(beacon, initData));
    }

    /// @notice Computes the deterministic address a BeaconProxy would be deployed to.
    function predictAddress(address beacon, bytes32 salt, bytes memory initData, address deployer)
        internal
        pure
        returns (address predicted)
    {
        bytes memory creationCode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, initData));
        predicted = Create2.computeAddress(salt, keccak256(creationCode), deployer);
    }
}
