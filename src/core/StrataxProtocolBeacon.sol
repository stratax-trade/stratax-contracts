// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IStrataxProtocolBeacon} from "../interfaces/internal/IStrataxProtocolBeacon.sol";

contract StrataxProtocolBeacon is UpgradeableBeacon, IStrataxProtocolBeacon {
    bytes32 public immutable lendingProtocolId;
    bytes32 public immutable swapProtocolId;

    constructor(address implementation_, address initialOwner_, bytes32 lendingProtocolId_, bytes32 swapProtocolId_)
        UpgradeableBeacon(implementation_, initialOwner_)
    {
        require(lendingProtocolId_ != bytes32(0), "Invalid lending protocol id");
        require(swapProtocolId_ != bytes32(0), "Invalid swap protocol id");
        lendingProtocolId = lendingProtocolId_;
        swapProtocolId = swapProtocolId_;
    }

    function supportsProtocolPair(bytes32 lendingProtocolId_, bytes32 swapProtocolId_)
        external
        view
        override
        returns (bool)
    {
        return lendingProtocolId_ == lendingProtocolId && swapProtocolId_ == swapProtocolId;
    }
}
