// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {StrataxAaveLib} from "../lending/StrataxAaveLib.sol";

library StrataxAavePositionInitConstants {
    // Ethereum mainnet Aave V3 contracts
    address internal constant ETHEREUM_AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant ETHEREUM_AAVE_DATA_PROVIDER = 0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD;

    // Strategy defaults (4-decimal precision)
    uint256 internal constant ETHEREUM_DEFAULT_BORROW_SAFETY_MARGIN = 9950;
    uint256 internal constant ETHEREUM_DEFAULT_MAX_LEVERAGE_OFFSET = 75;

    function ethereumPositionInitParams() internal pure returns (StrataxAaveLib.PositionInitParams memory params) {
        params = StrataxAaveLib.PositionInitParams({
            aavePool: ETHEREUM_AAVE_POOL,
            aaveDataProvider: ETHEREUM_AAVE_DATA_PROVIDER,
            borrowSafetyMargin: ETHEREUM_DEFAULT_BORROW_SAFETY_MARGIN,
            maxLeverageOffset: ETHEREUM_DEFAULT_MAX_LEVERAGE_OFFSET
        });
    }

    function ethereumConfigParams(uint256 flashLoanFeeBps)
        internal
        pure
        returns (StrataxAaveLib.InitParams memory params)
    {
        params = StrataxAaveLib.InitParams({
            pool: ETHEREUM_AAVE_POOL,
            dataProvider: ETHEREUM_AAVE_DATA_PROVIDER,
            flashLoanFeeBps: flashLoanFeeBps,
            defaultBorrowSafetyMargin: ETHEREUM_DEFAULT_BORROW_SAFETY_MARGIN,
            defaultMaxLeverageOffset: ETHEREUM_DEFAULT_MAX_LEVERAGE_OFFSET
        });
    }
}
