// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IStrataxPositionAdapter {
    function supportsProtocolPair(bytes32 lendingProtocolId, bytes32 swapProtocolId) external view returns (bool);

    function openPositionSchemaId() external pure returns (bytes32 schemaId);

    function openPositionSchemaVersion() external pure returns (uint16 schemaVersion);

    function encodeOpenPositionData(
        uint256 collateralAmount,
        uint256 leverage,
        uint256 minAmountOut,
        bytes calldata adapterData
    ) external pure returns (bytes memory openPositionData);

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

    function openPosition(uint256 tokenId, address strataxProxy, bytes calldata openPositionData) external;
}
