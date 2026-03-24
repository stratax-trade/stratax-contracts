// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

library StrataxUniswapLib {
    struct InitParams {
        address uniswapRouter;
    }

    struct Config {
        address router;
        address quoter;
        uint24 poolFee;
    }

    function decodeConfig(bytes memory configData) internal pure returns (Config memory config) {
        require(configData.length > 0, "Missing uniswap config");
        config = abi.decode(configData, (Config));
    }

    function hasValidCoreConfig(Config memory config) internal pure returns (bool) {
        return config.router != address(0) && config.quoter != address(0) && config.poolFee > 0;
    }

    function validateTokenPair(address collateralToken, address borrowToken, bytes memory configData)
        internal
        pure
        returns (bool isValid)
    {
        if (collateralToken == address(0) || borrowToken == address(0)) {
            return false;
        }

        if (collateralToken == borrowToken) {
            return false;
        }

        Config memory config = decodeConfig(configData);
        return hasValidCoreConfig(config);
    }
}
