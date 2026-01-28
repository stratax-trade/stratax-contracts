// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @title IProtocolDataProvider
 * @notice Interface for Aave's ProtocolDataProvider contract
 * @dev Used to query reserve configuration data including LTV ratios
 */
interface IProtocolDataProvider {
    /**
     * @notice Returns the configuration data for a reserve
     * @param asset The address of the underlying asset
     * @return decimals The decimals of the reserve
     * @return ltv The loan to value ratio (in basis points)
     * @return liquidationThreshold The liquidation threshold (in basis points)
     * @return liquidationBonus The liquidation bonus (in basis points)
     * @return reserveFactor The reserve factor (in basis points)
     * @return usageAsCollateralEnabled True if the asset can be used as collateral
     * @return borrowingEnabled True if borrowing is enabled
     * @return stableBorrowRateEnabled True if stable borrow rate is enabled
     * @return isActive True if the reserve is active
     * @return isFrozen True if the reserve is frozen
     */
    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        );

    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);
}
