// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @title StrataxCalculations
 * @notice Library containing core calculation logic for leveraged positions
 * @dev This library is used by both Stratax and StrataxPositionNft contracts
 */
library StrataxCalculations {
    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constant for basis points calculations (100% = 10000)
    /// @dev 100% = 10,000, 1% = 100, 0.01% = 1
    uint256 public constant FLASHLOAN_FEE_PREC = 1e4;

    /// @notice Precision used for price feeds (8 decimals)
    uint256 public constant PRICE_FEED_PREC = 1e8;

    /// @notice Precision for loan-to-value ratios (4 decimals, e.g., 8000 = 80%)
    uint256 public constant LTV_PRECISION = 1e4;

    /// @notice Precision for leverage calculations (4 decimals, e.g., 30000 = 3x)
    uint256 public constant LEVERAGE_PRECISION = 1e4;

    /// @notice Precision for borrow safety margin (4 decimals, e.g., 9900 = 99%)
    uint256 public constant BORROW_SAFETY_PRECISION = 1e4;

    /// @notice Precision for max leverage offset (4 decimals, e.g., 75 = 0.75%)
    uint256 public constant MAX_LEVERAGE_OFFSET_PRECISION = 1e4;

    /// @notice Base collateral constant for leverage calculations (virtual unit)
    uint256 public constant BASE_COLLATERAL = 1e18;

    /*//////////////////////////////////////////////////////////////
                            STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Parameters for calculating leveraged position open params
    struct CalcParams {
        /// @notice Desired leverage multiplier with 4 decimals (e.g., 30000 = 3x)
        uint256 desiredLeverage;
        /// @notice Amount of collateral the user will provide (in collateral token units)
        uint256 collateralAmount;
        /// @notice Price of collateral token in USD with 8 decimals
        uint256 collateralTokenPrice;
        /// @notice Price of borrow token in USD with 8 decimals
        uint256 borrowTokenPrice;
        /// @notice Decimals of the collateral token
        uint256 collateralTokenDecimals;
        /// @notice Decimals of the borrow token
        uint256 borrowTokenDecimals;
        /// @notice Loan-to-value ratio from Aave with 4 decimals (e.g., 8000 = 80%)
        uint256 ltv;
        /// @notice Borrow safety margin with 4 decimals (e.g., 9900 = 99%)
        uint256 borrowSafetyMargin;
        /// @notice Flash loan fee in basis points (e.g., 9 = 0.09%)
        uint256 flashLoanFeeBps;
        /// @notice Stratax protocol fee in basis points
        uint256 strataxFeeBps;
        /// @notice Max leverage offset with 4 decimals (e.g., 75 = 0.75%)
        uint256 maxLeverageOffset;
    }

    /// @notice Result of position calculation
    struct CalcResult {
        /// @notice Amount to flash loan (in collateral token units)
        uint256 flashLoanAmount;
        /// @notice Amount to borrow from Aave (in borrow token units)
        uint256 borrowAmount;
        /// @notice Stratax protocol fee amount (in collateral token units)
        uint256 strataxFee;
        /// @notice Adjusted leverage if capped by max achievable
        uint256 adjustedLeverage;
    }

    /*//////////////////////////////////////////////////////////////
                            FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates the flash loan and borrow amounts needed to achieve desired leverage
     * @dev This is a pure calculation function without any state access or events
     * @param params Struct containing all calculation parameters
     * @return result Struct containing flash loan amount, borrow amount, fee, and adjusted leverage
     */
    function calculateOpenParams(CalcParams memory params) internal pure returns (CalcResult memory result) {
        require(params.collateralAmount > 0, "Collateral must be > 0");
        require(params.desiredLeverage >= LEVERAGE_PRECISION, "Leverage must be >= 1x");
        require(params.collateralTokenPrice > 0, "Collateral token price must be > 0");
        require(params.borrowTokenPrice > 0, "Borrow token price must be > 0");
        require(params.ltv > 0, "Asset not usable as collateral");

        // Validate desired leverage doesn't exceed theoretical maximum
        uint256 maxLeverage = (LEVERAGE_PRECISION * LEVERAGE_PRECISION) / (LTV_PRECISION - params.ltv);
        require(params.desiredLeverage <= maxLeverage, "Desired leverage exceeds maximum");

        // Calculate max achievable leverage considering fees and safety margins
        uint256 actualMaxLeverage = getMaxAchievableLeverageBinary(
            params.ltv,
            params.borrowSafetyMargin,
            params.maxLeverageOffset,
            params.flashLoanFeeBps,
            params.strataxFeeBps
        );

        // Cap desired leverage at actual max achievable
        if (params.desiredLeverage > actualMaxLeverage) {
            params.desiredLeverage = actualMaxLeverage;
        }

        // Calculate and apply Stratax fee
        result.strataxFee = (params.collateralAmount * params.strataxFeeBps * params.desiredLeverage)
            / (FLASHLOAN_FEE_PREC * LEVERAGE_PRECISION);

        uint256 collateralAfterFee = params.collateralAmount - result.strataxFee;

        // Flash loan amount = collateral × (leverage - 1)
        result.flashLoanAmount =
            (collateralAfterFee * (params.desiredLeverage - LEVERAGE_PRECISION)) / LEVERAGE_PRECISION;

        // Calculate flash loan fee
        uint256 flashLoanFee = (result.flashLoanAmount * params.flashLoanFeeBps) / FLASHLOAN_FEE_PREC;

        // Total collateral to supply = user collateral (after fee) + flash loan
        // Note: Flash loan fee is NOT subtracted here - it's paid from swap proceeds
        uint256 totalCollateral = collateralAfterFee + result.flashLoanAmount;

        // Calculate total collateral value in USD (with 8 decimals)
        uint256 totalCollateralValueUsd =
            (totalCollateral * params.collateralTokenPrice) / (10 ** params.collateralTokenDecimals);

        // Calculate borrow value in USD with safety margin
        uint256 borrowValueUsd = (totalCollateralValueUsd * params.ltv * params.borrowSafetyMargin)
            / (LTV_PRECISION * BORROW_SAFETY_PRECISION);

        // Convert borrow value to borrow token amount
        result.borrowAmount = (borrowValueUsd * (10 ** params.borrowTokenDecimals)) / params.borrowTokenPrice;

        // Validate that borrowed amount when swapped back covers flash loan + fee
        uint256 minRequiredAfterSwap = result.flashLoanAmount + flashLoanFee;
        uint256 borrowValueInCollateral =
            (result.borrowAmount * params.borrowTokenPrice * (10 ** params.collateralTokenDecimals))
                / (params.collateralTokenPrice * (10 ** params.borrowTokenDecimals));

        require(borrowValueInCollateral >= minRequiredAfterSwap, "Insufficient borrow to repay flash loan");

        result.adjustedLeverage = params.desiredLeverage;

        return result;
    }

    /**
     * @notice Calculates the maximum theoretical leverage for a given LTV (without fees/margins)
     * @param _ltv The loan-to-value ratio with 4 decimals (e.g., 8000 = 80%)
     * @return maxLeverage The maximum leverage with 4 decimals (e.g., 50000 = 5x)
     */
    function getMaxLeverage(uint256 _ltv) internal pure returns (uint256 maxLeverage) {
        require(_ltv > 0 && _ltv < LTV_PRECISION, "Invalid LTV");

        // Maximum leverage = 1 / (1 - LTV)
        // With 4 decimal precision: maxLeverage = 10000 / (10000 - ltv)
        maxLeverage = (LEVERAGE_PRECISION * LEVERAGE_PRECISION) / (LTV_PRECISION - _ltv);
    }

    /**
     * @notice Calculates the maximum achievable leverage considering fees and safety margins
     * @dev Uses binary search to find the highest safe leverage
     * @param ltv Loan-to-value ratio with 4 decimals (e.g., 8000 = 80%)
     * @param borrowSafetyMargin Borrow safety margin with 4 decimals (e.g., 9900 = 99%)
     * @param maxLeverageOffset Max leverage offset with 4 decimals (e.g., 75 = 0.75%)
     * @param flashLoanFeeBps Flash loan fee in basis points
     * @param strataxFeeBps Stratax protocol fee in basis points
     * @return maxLeverage The maximum achievable leverage with 4 decimals
     */
    function getMaxAchievableLeverageBinary(
        uint256 ltv,
        uint256 borrowSafetyMargin,
        uint256 maxLeverageOffset,
        uint256 flashLoanFeeBps,
        uint256 strataxFeeBps
    ) internal pure returns (uint256 maxLeverage) {
        require(ltv > 0, "Asset not collateralizable");

        uint256 effectiveLtv = (ltv * (borrowSafetyMargin - maxLeverageOffset)) / BORROW_SAFETY_PRECISION;
        require(effectiveLtv > 0, "Invalid effective LTV");

        // Search range: [1x, theoretical max]
        uint256 low = LEVERAGE_PRECISION;
        uint256 high = getMaxLeverage(ltv);
        uint256 best = low;

        while (low <= high) {
            uint256 mid = low + (high - low) / 2;

            if (_isLeverageSafe(mid, effectiveLtv, strataxFeeBps, flashLoanFeeBps)) {
                best = mid;
                low = mid + 1;
            } else {
                high = mid - 1;
            }
        }

        return best;
    }

    /**
     * @notice Checks if a given leverage level is safe considering all fees
     * @dev Uses virtual collateral amount for calculations
     * @param leverage The leverage to check with 4 decimals
     * @param effectiveLtv The effective LTV including safety margin
     * @param strataxFeeBps Stratax protocol fee in basis points
     * @param flashLoanFeeBps Flash loan fee in basis points
     * @return isSafe True if the leverage is achievable
     */
    function _isLeverageSafe(uint256 leverage, uint256 effectiveLtv, uint256 strataxFeeBps, uint256 flashLoanFeeBps)
        private
        pure
        returns (bool isSafe)
    {
        // Borrowed amount to reach leverage L: borrowed = C * (L - 1)
        uint256 borrowed = (BASE_COLLATERAL * (leverage - LEVERAGE_PRECISION)) / LEVERAGE_PRECISION;

        // Flash loan fee
        uint256 flashFee = (borrowed * flashLoanFeeBps) / FLASHLOAN_FEE_PREC;

        uint256 totalDebt = borrowed + flashFee;

        // Stratax fee scales with notional × leverage: fee = C * L * strataxFee
        uint256 protocolFee = (BASE_COLLATERAL * leverage * strataxFeeBps) / (LEVERAGE_PRECISION * FLASHLOAN_FEE_PREC);

        // Effective collateral after protocol fee
        if (protocolFee >= BASE_COLLATERAL) return false;

        uint256 effectiveCollateral = (BASE_COLLATERAL + borrowed) - protocolFee;

        // Max borrow allowed by Aave LTV
        uint256 maxBorrow = (effectiveCollateral * effectiveLtv) / FLASHLOAN_FEE_PREC;

        return totalDebt <= maxBorrow;
    }
}
