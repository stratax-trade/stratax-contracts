// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

library Stratax1InchLib {
    struct InitParams {
        address oneInchRouter;
    }

    struct Config {
        address router;
    }

    function decodeConfig(bytes memory configData) internal pure returns (Config memory config) {
        require(configData.length > 0, "Missing swap config");
        config = abi.decode(configData, (Config));
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
        return config.router != address(0);
    }
}
