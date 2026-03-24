// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

library StrataxFluidLib {
    struct PositionInitParams {
        address fluidVault;
        uint256 borrowSafetyMargin;
        uint256 maxLeverageOffset;
    }

    struct InitParams {
        address vault;
        uint256 defaultBorrowSafetyMargin;
        uint256 defaultMaxLeverageOffset;
    }

    function decodeConfig(bytes memory configData) internal pure returns (InitParams memory config) {
        require(configData.length > 0, "Missing lending config");
        config = abi.decode(configData, (InitParams));
    }

    function hasValidCoreConfig(InitParams memory config) internal pure returns (bool) {
        return config.vault != address(0);
    }

    function validateTokenPair(address collateralToken, address borrowToken, address vault)
        internal
        pure
        returns (bool isValid)
    {
        if (vault == address(0) || collateralToken == address(0) || borrowToken == address(0)) {
            return false;
        }

        return collateralToken != borrowToken;
    }
}
