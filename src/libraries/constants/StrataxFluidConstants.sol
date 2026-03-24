// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {StrataxFluidLib} from "../lending/StrataxFluidLib.sol";

library StrataxFluidConstants {
    // Ethereum mainnet Fluid Vault (example WETH/USDC market vault).
    // Override per pair/network via StrataxConfigManager when needed.
    address internal constant ETHEREUM_FLUID_VAULT = 0x0C8C77B7FF4c2aF7F6CEBbe67350A490E3DD6cB3;

    uint256 internal constant DEFAULT_BORROW_SAFETY_MARGIN = 9900;
    uint256 internal constant DEFAULT_MAX_LEVERAGE_OFFSET = 100;

    function ethereumPositionInitParams() internal pure returns (StrataxFluidLib.PositionInitParams memory params) {
        params = StrataxFluidLib.PositionInitParams({
            fluidVault: ETHEREUM_FLUID_VAULT,
            borrowSafetyMargin: DEFAULT_BORROW_SAFETY_MARGIN,
            maxLeverageOffset: DEFAULT_MAX_LEVERAGE_OFFSET
        });
    }

    function ethereumConfigParams() internal pure returns (StrataxFluidLib.InitParams memory params) {
        params = StrataxFluidLib.InitParams({
            vault: ETHEREUM_FLUID_VAULT,
            defaultBorrowSafetyMargin: DEFAULT_BORROW_SAFETY_MARGIN,
            defaultMaxLeverageOffset: DEFAULT_MAX_LEVERAGE_OFFSET
        });
    }
}
