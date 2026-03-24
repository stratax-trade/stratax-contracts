// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IProtocolDataProvider} from "../../interfaces/external/IProtocolDataProvider.sol";

library StrataxAaveLib {
    struct PositionInitParams {
        address aavePool;
        address aaveDataProvider;
        uint256 borrowSafetyMargin;
        uint256 maxLeverageOffset;
    }

    struct InitParams {
        address pool;
        address dataProvider;
        uint256 flashLoanFeeBps;
        uint256 defaultBorrowSafetyMargin;
        uint256 defaultMaxLeverageOffset;
    }

    function decodeConfig(bytes memory configData) internal pure returns (InitParams memory config) {
        require(configData.length > 0, "Missing lending config");
        config = abi.decode(configData, (InitParams));
    }

    function hasValidCoreConfig(InitParams memory config) internal pure returns (bool) {
        return config.pool != address(0) && config.dataProvider != address(0);
    }

    function validateTokenPair(address collateralToken, address borrowToken, address dataProvider)
        internal
        view
        returns (bool isValid)
    {
        if (collateralToken == address(0) || borrowToken == address(0) || dataProvider == address(0)) {
            return false;
        }

        if (collateralToken == borrowToken) {
            return false;
        }

        return _isValidCollateralToken(collateralToken, dataProvider) && _isValidBorrowToken(borrowToken, dataProvider);
    }

    function _isValidCollateralToken(address token, address dataProvider) private view returns (bool) {
        (bool ok, bytes memory data) = dataProvider.staticcall(
            abi.encodeWithSelector(IProtocolDataProvider.getReserveConfigurationData.selector, token)
        );
        if (!ok) {
            return false;
        }

        (, uint256 ltv,,,, bool usageAsCollateralEnabled,,, bool isActive, bool isFrozen) =
            abi.decode(data, (uint256, uint256, uint256, uint256, uint256, bool, bool, bool, bool, bool));

        return isActive && !isFrozen && usageAsCollateralEnabled && ltv > 0;
    }

    function _isValidBorrowToken(address token, address dataProvider) private view returns (bool) {
        (bool ok, bytes memory data) = dataProvider.staticcall(
            abi.encodeWithSelector(IProtocolDataProvider.getReserveConfigurationData.selector, token)
        );
        if (!ok) {
            return false;
        }

        (,,,,,, bool borrowingEnabled,, bool isActive, bool isFrozen) =
            abi.decode(data, (uint256, uint256, uint256, uint256, uint256, bool, bool, bool, bool, bool));

        return isActive && !isFrozen && borrowingEnabled;
    }
}
