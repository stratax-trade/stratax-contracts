// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IStrataxProtocolBeacon {
    function supportsProtocolPair(bytes32 lendingProtocolId, bytes32 swapProtocolId) external view returns (bool);
}
