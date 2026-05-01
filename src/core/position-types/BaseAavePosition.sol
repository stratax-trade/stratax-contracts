// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPool} from "../../interfaces/external/IPool.sol";
import {IProtocolDataProvider} from "../../interfaces/external/IProtocolDataProvider.sol";
import {IStrataxOracle} from "../../interfaces/internal/IStrataxOracle.sol";
import {IFeeCollector} from "../../interfaces/internal/IFeeCollector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StrataxCalculations} from "../../libraries/StrataxCalculations.sol";
import {StrataxAaveLib} from "../../libraries/lending/StrataxAaveLib.sol";
import {StrataxCoreLib} from "../../libraries/stratax/StrataxCoreLib.sol";
import {BaseStrataxPosition} from "./BaseStrataxPosition.sol";

/**
 * @title BaseAavePosition
 * @notice Abstract base for all Aave-powered leveraged positions.
 * @dev Extracts Aave-specific state and logic so different DEXes can reuse lending orchestration.
 */
abstract contract BaseAavePosition is BaseStrataxPosition {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public constant VARIABLE_DEBT = 2;

    IPool public aavePool;
    IProtocolDataProvider public aaveDataProvider;
    uint256 public flashLoanFeeBps;

    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event FlashLoanFeeUpdated(uint256 newFeeBps, uint256 oldFeeBps);
    event CollateralSupplied(address indexed user, address collateralToken, uint256 amount, uint256 healthFactor);
    event CollateralWithdrawn(address indexed user, address collateralToken, uint256 amount, uint256 healthFactor);

    /*//////////////////////////////////////////////////////////////
                          INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function _initializeAave(
        IPool _aavePool,
        IProtocolDataProvider _aaveDataProvider,
        StrataxCoreLib.InitParams calldata strataxParams,
        uint256 _borrowSafetyMargin,
        uint256 _maxLeverageOffset
    ) internal onlyInitializing {
        require(address(_aavePool) != address(0), "Invalid Aave pool");
        require(address(_aaveDataProvider) != address(0), "Invalid Aave data provider");

        _initBase(strataxParams, _borrowSafetyMargin, _maxLeverageOffset);

        aavePool = _aavePool;
        aaveDataProvider = _aaveDataProvider;
        flashLoanFeeBps = _aavePool.FLASHLOAN_PREMIUM_TOTAL();
    }

    /*//////////////////////////////////////////////////////////////
                     AAVE-SPECIFIC CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates open parameters for a given leverage and collateral.
     * @param desiredLeverage Target leverage with 4 decimals (e.g., 30000 = 3x)
     * @param collateralAmount Amount of collateral user provides
     * @return flashLoanAmount Amount to flash loan from Aave
     * @return borrowAmount Amount to borrow from Aave
     * @return strataxFee Protocol fee amount
     */
    function calculateOpenParams(uint256 desiredLeverage, uint256 collateralAmount)
        public
        view
        returns (uint256 flashLoanAmount, uint256 borrowAmount, uint256 strataxFee)
    {
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(collateralToken);
        require(ltv > 0, "Asset not usable as collateral");

        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        uint256 borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);

        require(collateralTokenPrice > 0, "Collateral token price must be > 0");
        require(borrowTokenPrice > 0, "Borrow token price must be > 0");

        uint256 freeCollateral = _getFreeCollateral(collateralTokenPrice, borrowTokenPrice, ltv);
        uint256 totalCollateralAmount = collateralAmount + freeCollateral;
        require(totalCollateralAmount > 0, "Collateral must be > 0");

        StrataxCalculations.CalcParams memory calcParams = StrataxCalculations.CalcParams({
            desiredLeverage: desiredLeverage,
            collateralAmount: totalCollateralAmount,
            collateralTokenPrice: collateralTokenPrice,
            borrowTokenPrice: borrowTokenPrice,
            collateralTokenDecimals: collateralTokenDecimals,
            borrowTokenDecimals: borrowTokenDecimals,
            ltv: ltv,
            borrowSafetyMargin: borrowSafetyMargin,
            flashLoanFeeBps: flashLoanFeeBps,
            strataxFeeBps: IFeeCollector(feeCollector).strataxFee(),
            maxLeverageOffset: maxLeverageOffset
        });

        StrataxCalculations.CalcResult memory result = StrataxCalculations.calculateOpenParams(calcParams);
        return (result.flashLoanAmount, result.borrowAmount, result.strataxFee);
    }

    /**
     * @notice Calculates parameters for unwinding a leveraged position
     */
    function calculateUnwindParams(uint256 debtToRepay)
        public
        view
        returns (uint256 collateralToWithdraw, uint256 debtAmount, uint256 strataxFee)
    {
        return calculateUnwindParams(debtToRepay, DEFAULT_SLIPPAGE_BPS);
    }

    /**
     * @notice Calculates parameters for unwinding a leveraged position with custom slippage
     */
    function calculateUnwindParams(uint256 debtToRepay, uint256 slippageBufferBps)
        public
        view
        returns (uint256 collateralToWithdraw, uint256 debtAmount, uint256 strataxFee)
    {
        (,, address variableDebtToken) = aaveDataProvider.getReserveTokensAddresses(borrowToken);
        debtAmount = IERC20(variableDebtToken).balanceOf(address(this));
        if (debtAmount <= debtToRepay) {
            debtToRepay = debtAmount;
        }

        uint256 debtTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);

        strataxFee = (debtToRepay * IFeeCollector(feeCollector).strataxFee()) / StrataxCalculations.FLASHLOAN_FEE_PREC;
        uint256 flashLoanFeeAmount = (debtToRepay * flashLoanFeeBps) / StrataxCalculations.FLASHLOAN_FEE_PREC;

        collateralToWithdraw =
            (debtTokenPrice * (debtToRepay + flashLoanFeeAmount + strataxFee) * (10 ** collateralTokenDecimals))
                / (collateralTokenPrice * (10 ** borrowTokenDecimals));

        collateralToWithdraw =
            (collateralToWithdraw * (StrataxCalculations.BPS + slippageBufferBps)) / StrataxCalculations.BPS;

        return (collateralToWithdraw, debtToRepay, strataxFee);
    }

    /*//////////////////////////////////////////////////////////////
                     AAVE-SPECIFIC ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns free collateral available in the Aave position
     */
    function _getFreeCollateral(uint256 collateralTokenPrice, uint256 borrowTokenPrice, uint256 ltv)
        internal
        view
        returns (uint256 freeCollateral)
    {
        (address aTokenCollateral,,) = aaveDataProvider.getReserveTokensAddresses(collateralToken);
        uint256 aTokenBalance = IERC20(aTokenCollateral).balanceOf(address(this));

        (,, address variableDebtToken) = aaveDataProvider.getReserveTokensAddresses(borrowToken);
        uint256 debtTokenAmount = IERC20(variableDebtToken).balanceOf(address(this));

        uint256 collateralBackingDebt = (debtTokenAmount * borrowTokenPrice * (10 ** collateralTokenDecimals))
            / (collateralTokenPrice * (10 ** borrowTokenDecimals));
        require(ltv > 0, "Invalid LTV");

        collateralBackingDebt = (collateralBackingDebt * StrataxCalculations.LTV_PRECISION + ltv - 1) / ltv;

        if (aTokenBalance >= collateralBackingDebt) {
            freeCollateral = aTokenBalance - collateralBackingDebt;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    OVERRIDES: BaseStrataxPosition
    //////////////////////////////////////////////////////////////*/

    function _getTotalCollateralAndDebt() internal view override returns (uint256 totalCollateral, uint256 totalDebt) {
        (address aTokenCollateral,,) = aaveDataProvider.getReserveTokensAddresses(collateralToken);
        (,, address variableDebtToken) = aaveDataProvider.getReserveTokensAddresses(borrowToken);
        totalCollateral = IERC20(aTokenCollateral).balanceOf(address(this));
        totalDebt = IERC20(variableDebtToken).balanceOf(address(this));
    }

    function _getCollateralLtv() internal view override returns (uint256) {
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(collateralToken);
        return ltv;
    }

    function getMaxAchievableLeverageBinary() public view override returns (uint256) {
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(collateralToken);
        if (ltv == 0 || ltv >= StrataxCalculations.LTV_PRECISION) {
            return 0;
        }

        return StrataxCalculations.getMaxAchievableLeverageBinary(
            ltv, borrowSafetyMargin, maxLeverageOffset, flashLoanFeeBps, IFeeCollector(feeCollector).strataxFee()
        );
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function supplyCollateral(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than zero");

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(collateralToken).forceApprove(address(aavePool), amount);
        aavePool.supply(collateralToken, amount, address(this), 0);

        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        emit CollateralSupplied(msg.sender, collateralToken, amount, healthFactor);
    }

    function withdrawCollateral(uint256 amount) external onlyOwner returns (uint256 amountWithdrawn) {
        require(amount > 0, "Amount must be greater than zero");

        amountWithdrawn = aavePool.withdraw(collateralToken, amount, msg.sender);
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        require(healthFactor > 1e18, "Withdrawal would make position unhealthy");

        emit CollateralWithdrawn(msg.sender, collateralToken, amountWithdrawn, healthFactor);
        return amountWithdrawn;
    }

    function borrowDebtToken(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than zero");

        aavePool.borrow(borrowToken, amount, VARIABLE_DEBT, 0, address(this));
        IERC20(borrowToken).safeTransfer(msg.sender, amount);

        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        require(healthFactor > 1e18, "Borrow would make position unhealthy");
    }

    function repayDebtToken(uint256 amount) external onlyOwner returns (uint256 amountRepaid) {
        require(amount > 0, "Amount must be greater than zero");

        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(borrowToken).forceApprove(address(aavePool), amount);

        amountRepaid = aavePool.repay(borrowToken, amount, VARIABLE_DEBT, address(this));
    }

    function updateFlashLoanFee() external onlyOwner {
        uint256 oldFee = flashLoanFeeBps;
        flashLoanFeeBps = aavePool.FLASHLOAN_PREMIUM_TOTAL();
        require(flashLoanFeeBps < StrataxCalculations.FLASHLOAN_FEE_PREC, "Fee must be < 100%");
        emit FlashLoanFeeUpdated(flashLoanFeeBps, oldFee);
    }
}
