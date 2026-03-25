// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IStrataxPositionAdapter {
    function supportsProtocolPair(bytes32 lendingProtocolId, bytes32 swapProtocolId) external view returns (bool);

    function validateLendingTokens(address collateralToken, address borrowToken, bytes calldata lendingConfigData)
        external
        view
        returns (bool isValid);

    function validateSwapTokens(address collateralToken, address borrowToken, bytes calldata swapConfigData)
        external
        view
        returns (bool isValid);

    function deployAndInitialize(
        bytes calldata lendingConfigData,
        bytes calldata swapConfigData,
        bytes calldata strataxInitConfig,
        bytes32 deploymentSalt
    ) external returns (address strataxProxy);

    function predictDeploymentAddress(
        bytes calldata lendingConfigData,
        bytes calldata swapConfigData,
        bytes calldata strataxInitConfig,
        bytes32 deploymentSalt
    ) external view returns (address predictedStrataxProxy);
}
