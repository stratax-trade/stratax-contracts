// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {StrataxUniswapLib} from "../swapping/StrataxUniswapLib.sol";

library StrataxUniswapConstants {
    // Ethereum mainnet Uniswap V3 contracts
    address internal constant ETHEREUM_UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant ETHEREUM_UNISWAP_V3_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    // Canonical fee tier for blue-chip pairs such as WETH/USDC (0.3%)
    uint24 internal constant ETHEREUM_DEFAULT_UNISWAP_POOL_FEE = 3000;

    function ethereumPositionInitParams() internal pure returns (StrataxUniswapLib.InitParams memory params) {
        params = StrataxUniswapLib.InitParams({uniswapRouter: ETHEREUM_UNISWAP_V3_ROUTER});
    }

    function ethereumConfigParams() internal pure returns (StrataxUniswapLib.Config memory params) {
        params = StrataxUniswapLib.Config({
            router: ETHEREUM_UNISWAP_V3_ROUTER,
            quoter: ETHEREUM_UNISWAP_V3_QUOTER_V2,
            poolFee: ETHEREUM_DEFAULT_UNISWAP_POOL_FEE
        });
    }
}
