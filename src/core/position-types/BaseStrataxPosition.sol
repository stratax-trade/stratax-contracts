// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IStrataxOracle} from "../../interfaces/internal/IStrataxOracle.sol";
import {IStrataxPositionNft} from "../../interfaces/internal/IStrataxPositionNft.sol";
import {IFeeCollector} from "../../interfaces/internal/IFeeCollector.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {StrataxCalculations} from "../../libraries/StrataxCalculations.sol";
import {StrataxCoreLib} from "../../libraries/stratax/StrataxCoreLib.sol";

/**
 * @title BaseStrataxPosition
 * @author Stratax
 * @notice Abstract base contract for all Stratax leveraged position types.
 * @dev Provides common state, ownership, lifecycle (burn/recover), and view
 *      functions (getCurrentLeverage, getPositionUsdValue). Concrete implementations
 *      must override `_getTotalCollateralAndDebt()` to return protocol-specific balances.
 */
abstract contract BaseStrataxPosition is Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Default unwind slippage buffer in basis points (50 = 0.50%)
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 50;

    /// @notice tokenId which represents this contract in the StrataxPositionNft
    uint256 public tokenId;

    /// @notice if the token has been burned
    bool public isBurned;

    /// @notice owner of the burned token
    address public burnedTokenOwner;

    /// @notice Safety margin for borrow calculations (9900 = 99% of max LTV)
    uint256 public borrowSafetyMargin;

    /// @notice Offset from maximum leverage with 4 decimals (e.g., 75 = 0.75%)
    uint256 public maxLeverageOffset;

    /// @notice StrataxPositionNft contract for tracking ownership
    IStrataxPositionNft public strataxPositionNft;

    /// @notice Collateral token address for this position
    address public collateralToken;

    /// @notice Borrow token address for this position
    address public borrowToken;

    /// @notice Decimals of the collateral token
    uint256 public collateralTokenDecimals;

    /// @notice Decimals of the borrow token
    uint256 public borrowTokenDecimals;

    /// @notice Address of the Stratax price oracle contract
    address public strataxOracle;

    /// @notice Address for the fee collector which takes an opening and closing fee
    address public feeCollector;

    /// @notice Storage gap for future base contract additions
    uint256[40] private __baseGap;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event LeveragePositionCreated(
        address indexed user,
        address collateralToken,
        address borrowedToken,
        uint256 totalCollateralSupplied,
        uint256 borrowedAmount
    );

    event PositionUnwound(
        address indexed user, address collateralToken, address debtToken, uint256 debtRepaid, uint256 collateralReturned
    );

    event PositionBurned(address indexed user, uint256 tokenId);

    event BorrowSafetyMarginUpdated(uint256 newMargin, uint256 oldMargin);

    event MaxLeverageOffsetUpdated(uint256 newOffset, uint256 oldOffset);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (isBurned) {
            require(msg.sender == burnedTokenOwner, "Not Owner");
        } else {
            require(msg.sender == strataxPositionNft.ownerOf(tokenId), "Not Owner");
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL INIT
    //////////////////////////////////////////////////////////////*/

    function _initBase(
        StrataxCoreLib.InitParams calldata strataxParams,
        uint256 _borrowSafetyMargin,
        uint256 _maxLeverageOffset
    ) internal onlyInitializing {
        strataxPositionNft = IStrataxPositionNft(strataxParams.strataxPositionNft);
        tokenId = strataxParams.tokenId;
        collateralToken = strataxParams.collateralToken;
        borrowToken = strataxParams.borrowToken;
        strataxOracle = strataxParams.strataxOracle;
        feeCollector = strataxParams.feeCollector;

        collateralTokenDecimals = IERC20Metadata(strataxParams.collateralToken).decimals();
        borrowTokenDecimals = IERC20Metadata(strataxParams.borrowToken).decimals();

        if (_borrowSafetyMargin == 0) {
            borrowSafetyMargin = 9900;
        } else {
            require(_borrowSafetyMargin < StrataxCalculations.BORROW_SAFETY_PRECISION, "Invalid safety margin");
            borrowSafetyMargin = _borrowSafetyMargin;
        }

        maxLeverageOffset = _maxLeverageOffset;
    }

    /*//////////////////////////////////////////////////////////////
                        VIRTUAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns protocol-specific collateral and debt balances in token units
    function _getTotalCollateralAndDebt() internal view virtual returns (uint256 totalCollateral, uint256 totalDebt);

    /// @notice Returns the loan-to-value ratio for the collateral token (4-decimal precision, e.g. 7500 = 75%).
    ///         Returns 0 when the protocol does not expose an LTV, causing getMaxLeverage() to return 0.
    function _getCollateralLtv() internal view virtual returns (uint256) {
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function owner() public view returns (address) {
        return strataxPositionNft.ownerOf(tokenId);
    }

    function getCollateralTokenAddress() external view returns (address) {
        return collateralToken;
    }

    function getBorrowTokenAddress() external view returns (address) {
        return borrowToken;
    }

    /// @notice Returns the maximum achievable leverage for this position's collateral token.
    /// @dev    Derived from the collateral LTV: max = (LEVERAGE_PREC² / (LTV_PREC - ltv)) - maxLeverageOffset.
    ///         Returns 0 when the underlying protocol does not provide an LTV (default _getCollateralLtv).
    function getMaxLeverage() public view virtual returns (uint256) {
        uint256 ltv = _getCollateralLtv();
        if (ltv == 0 || ltv >= StrataxCalculations.LTV_PRECISION) return 0;
        uint256 rawMax = (StrataxCalculations.LEVERAGE_PRECISION * StrataxCalculations.LEVERAGE_PRECISION)
            / (StrataxCalculations.LTV_PRECISION - ltv);
        if (rawMax <= maxLeverageOffset) return StrataxCalculations.LEVERAGE_PRECISION;
        return rawMax - maxLeverageOffset;
    }

    /// @notice Returns max achievable leverage accounting for fee model and safety margin.
    /// @dev Child contracts with protocol-specific fee models should override with exact logic.
    function getMaxAchievableLeverageBinary() public view virtual returns (uint256) {
        return getMaxLeverage();
    }

    function getCurrentLeverage() public view returns (uint256 currentLeverage) {
        (uint256 totalCollateral, uint256 totalDebt) = _getTotalCollateralAndDebt();

        if (totalCollateral == 0) return 0;
        if (totalDebt == 0) return StrataxCalculations.LEVERAGE_PRECISION;

        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        uint256 borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        require(collateralTokenPrice > 0, "Collateral token price must be > 0");
        require(borrowTokenPrice > 0, "Borrow token price must be > 0");

        uint256 totalCollateralValueUsd = (totalCollateral * collateralTokenPrice) / (10 ** collateralTokenDecimals);
        uint256 totalDebtValueUsd = (totalDebt * borrowTokenPrice) / (10 ** borrowTokenDecimals);

        if (totalCollateralValueUsd <= totalDebtValueUsd) return 0;

        uint256 equity = totalCollateralValueUsd - totalDebtValueUsd;
        currentLeverage = (totalCollateralValueUsd * StrataxCalculations.LEVERAGE_PRECISION) / equity;
    }

    function getPositionUsdValue() public view returns (uint256 positionValueUsd) {
        (uint256 totalCollateral, uint256 totalDebt) = _getTotalCollateralAndDebt();

        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        uint256 borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        require(collateralTokenPrice > 0, "Collateral token price must be > 0");
        require(borrowTokenPrice > 0, "Borrow token price must be > 0");

        uint256 totalCollateralValueUsd = (totalCollateral * collateralTokenPrice) / (10 ** collateralTokenDecimals);
        uint256 totalDebtValueUsd = (totalDebt * borrowTokenPrice) / (10 ** borrowTokenDecimals);

        if (totalCollateralValueUsd >= totalDebtValueUsd) {
            positionValueUsd = totalCollateralValueUsd - totalDebtValueUsd;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    LIFECYCLE & ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function burnPosition(address newOwner) external onlyOwner {
        strataxPositionNft.burn(tokenId);
        burnedTokenOwner = newOwner;
        isBurned = true;
        emit PositionBurned(msg.sender, tokenId);
    }

    function recoverTokens(address _token, uint256 _amount) external onlyOwner {
        require(isBurned, "Position must be burned to recover tokens");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    function updateBorrowSafetyMargin(uint256 newMargin) external onlyOwner {
        require(newMargin > 0 && newMargin < StrataxCalculations.BORROW_SAFETY_PRECISION, "Invalid safety margin");
        uint256 oldMargin = borrowSafetyMargin;
        borrowSafetyMargin = newMargin;
        emit BorrowSafetyMarginUpdated(newMargin, oldMargin);
    }

    function updateMaxLeverageOffset(uint256 newOffset) external onlyOwner {
        require(newOffset <= 500, "Max leverage offset too high");
        uint256 oldOffset = maxLeverageOffset;
        maxLeverageOffset = newOffset;
        emit MaxLeverageOffsetUpdated(newOffset, oldOffset);
    }
}
