// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {StrataxUniswapLib} from "../swapping/StrataxUniswapLib.sol";

library StrataxUniswapConstants {
    // Ethereum mainnet Uniswap V3 contracts
    address internal constant ETHEREUM_UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant ETHEREUM_UNISWAP_V3_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    // Sepolia testnet Uniswap V3 contracts
    // NOTE: SwapRouter V1 is not deployed on Sepolia. SwapRouter02 is used instead.
    // SwapRouter02 exactInputSingle has a different signature (no `deadline` param).
    // The protocol's IUniswapV3SwapRouter interface includes `deadline`, so the interface
    // must be updated or a V1-compatible router must be deployed for Sepolia.
    address internal constant SEPOLIA_UNISWAP_V3_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address internal constant SEPOLIA_UNISWAP_V3_QUOTER_V2 = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;

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

    function sepoliaPositionInitParams() internal pure returns (StrataxUniswapLib.InitParams memory params) {
        params = StrataxUniswapLib.InitParams({uniswapRouter: SEPOLIA_UNISWAP_V3_ROUTER});
    }

    function sepoliaConfigParams() internal pure returns (StrataxUniswapLib.Config memory params) {
        params = StrataxUniswapLib.Config({
            router: SEPOLIA_UNISWAP_V3_ROUTER,
            quoter: SEPOLIA_UNISWAP_V3_QUOTER_V2,
            poolFee: ETHEREUM_DEFAULT_UNISWAP_POOL_FEE
        });
    }
}
