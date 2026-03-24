// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Stratax1InchLib} from "../swapping/Stratax1InchLib.sol";

library Stratax1InchConstants {
    // Ethereum mainnet 1inch router
    address internal constant ETHEREUM_ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    function ethereumPositionInitParams() internal pure returns (Stratax1InchLib.InitParams memory params) {
        params = Stratax1InchLib.InitParams({oneInchRouter: ETHEREUM_ONEINCH_ROUTER});
    }

    function ethereumConfigParams() internal pure returns (Stratax1InchLib.Config memory params) {
        params = Stratax1InchLib.Config({router: ETHEREUM_ONEINCH_ROUTER});
    }
}
