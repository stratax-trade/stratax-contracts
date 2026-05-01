// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPool} from "../../interfaces/external/IPool.sol";
import {IProtocolDataProvider} from "../../interfaces/external/IProtocolDataProvider.sol";
import {ISwapExecutor} from "../interfaces/internal/ISwapExecutor.sol";
import {IStrataxOracle} from "../../interfaces/internal/IStrataxOracle.sol";
import {IFeeCollector} from "../../interfaces/internal/IFeeCollector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AaveFlashLoanHandler} from "../libraries/lending/AaveFlashLoanHandler.sol";
import {StrataxAaveLib} from "../../libraries/lending/StrataxAaveLib.sol";
import {StrataxUniswapLib} from "../../libraries/swapping/StrataxUniswapLib.sol";
import {StrataxCoreLib} from "../../libraries/stratax/StrataxCoreLib.sol";
import {StrataxCalculations} from "../../libraries/StrataxCalculations.sol";
import {BaseAavePosition} from "./BaseAavePosition.sol";
import {BaseUniswapPosition} from "./BaseUniswapPosition.sol";

/**
 * @title Stratax_Aave_Uniswap
 * @notice Aave V3 lending + Uniswap V3 swap position.
 * @dev Composes independent lending and swapping base contracts.
 */
contract Stratax_Aave_Uniswap is BaseAavePosition, BaseUniswapPosition {
    using SafeERC20 for IERC20;

    enum OperationType {
        OPEN,
        UNWIND
    }

    struct CalcOpenParams {
        uint256 desiredLeverage;
        uint256 collateralAmount;
        uint256 collateralTokenPrice;
        uint256 borrowTokenPrice;
    }

    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                          INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        StrataxAaveLib.PositionInitParams calldata lendingParams,
        StrataxUniswapLib.InitParams calldata swapParams,
        StrataxCoreLib.InitParams calldata strataxParams,
        ISwapExecutor _swapExecutor
    ) external initializer {
        _initializeAave(
            IPool(lendingParams.aavePool),
            IProtocolDataProvider(lendingParams.aaveDataProvider),
            strataxParams,
            lendingParams.borrowSafetyMargin,
            lendingParams.maxLeverageOffset
        );
        _initUniswapSwap(swapParams.uniswapRouter, _swapExecutor);
    }

    function createLeveragedPosition(
        uint256 desiredLeverage,
        uint256 collateralAmount,
        address[] calldata swapPath,
        uint24[] calldata swapFees,
        uint256 minReturnAmount
    ) public onlyOwner {
        bytes memory encodedSwapPath = _validateAndEncodeSwapPath(swapPath, swapFees, collateralToken, borrowToken);
        _createLeveragedPositionCommon(desiredLeverage, collateralAmount, encodedSwapPath, minReturnAmount);
    }

    function adjustPositionLeverage(
        uint256 desiredLeverage,
        address[] calldata swapPath,
        uint24[] calldata swapFees,
        uint256 minReturnAmount
    ) external onlyOwner {
        bytes memory encodedSwapPath = _validateAndEncodeSwapPath(swapPath, swapFees, collateralToken, borrowToken);
        _adjustPositionLeverageCommon(desiredLeverage, encodedSwapPath, minReturnAmount);
    }

    function unwindPosition(
        uint256 collateralToWithdraw,
        uint256 debtAmount,
        address[] calldata swapPath,
        uint24[] calldata swapFees,
        uint256 minReturnAmount
    ) public onlyOwner {
        bytes memory encodedSwapPath = _validateAndEncodeSwapPath(swapPath, swapFees, collateralToken, borrowToken);
        _unwindPositionCommon(collateralToWithdraw, debtAmount, encodedSwapPath, minReturnAmount);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        nonReentrant
        returns (bool)
    {
        require(msg.sender == address(aavePool), "Caller must be Aave Pool");
        require(initiator == address(this), "Initiator must be this contract");

        OperationType opType = abi.decode(params, (OperationType));
        if (opType == OperationType.OPEN) {
            (, address user, AaveFlashLoanHandler.OpenFlashLoanParams memory openParams) =
                abi.decode(params, (OperationType, address, AaveFlashLoanHandler.OpenFlashLoanParams));
            AaveFlashLoanHandler.executeOpen(
                aavePool, swapRouter, asset, amount, premium, swapExecutor, feeCollector, strataxOracle, openParams
            );
            emit LeveragePositionCreated(
                user, asset, openParams.borrowToken, openParams.collateralAmount, openParams.borrowAmount
            );
        } else {
            (, address user, AaveFlashLoanHandler.UnwindFlashLoanParams memory unwindParams) =
                abi.decode(params, (OperationType, address, AaveFlashLoanHandler.UnwindFlashLoanParams));
            AaveFlashLoanHandler.executeUnwind(
                aavePool, swapRouter, asset, amount, premium, swapExecutor, feeCollector, unwindParams
            );
            emit PositionUnwound(user, unwindParams.collateralToken, asset, amount, unwindParams.collateralToWithdraw);
        }

        return true;
    }

    function calculateOpenParams(CalcOpenParams calldata params)
        external
        view
        returns (uint256 flashLoanAmount, uint256 borrowAmount, uint256 strataxFee)
    {
        return _calculateOpenParamsWithOptionalPrices(
            params.desiredLeverage, params.collateralAmount, params.collateralTokenPrice, params.borrowTokenPrice
        );
    }

    function _calculateOpenParamsWithOptionalPrices(
        uint256 desiredLeverage,
        uint256 collateralAmount,
        uint256 collateralTokenPrice,
        uint256 borrowTokenPrice
    ) internal view returns (uint256 flashLoanAmount, uint256 borrowAmount, uint256 strataxFee) {
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(collateralToken);
        require(ltv > 0, "Asset not usable as collateral");

        if (collateralTokenPrice == 0) {
            collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        }
        if (borrowTokenPrice == 0) {
            borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        }

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

    function _createLeveragedPositionCommon(
        uint256 desiredLeverage,
        uint256 collateralAmount,
        bytes memory swapData,
        uint256 minReturnAmount
    ) internal {
        require(!isBurned, "Position is burned, only unwinding allowed");
        require(desiredLeverage >= StrataxCalculations.LEVERAGE_PRECISION, "Leverage must be >= 1x");

        (uint256 flashLoanAmount, uint256 borrowAmount, uint256 strataxFeeAmount) =
            calculateOpenParams(desiredLeverage, collateralAmount);

        _createLeveragedPositionPrecomputedCommon(
            flashLoanAmount, collateralAmount, borrowAmount, strataxFeeAmount, swapData, minReturnAmount
        );
    }

    function _createLeveragedPositionPrecomputedCommon(
        uint256 flashLoanAmount,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 strataxFeeAmount,
        bytes memory swapData,
        uint256 minReturnAmount
    ) internal {
        require(!isBurned, "Position is burned, only unwinding allowed");

        uint256 idleCollateral = IERC20(collateralToken).balanceOf(address(this));
        if (idleCollateral > 0) {
            IERC20(collateralToken).forceApprove(address(aavePool), idleCollateral);
            aavePool.supply(collateralToken, idleCollateral, address(this), 0);
        }

        if (collateralAmount > 0) {
            IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        }

        AaveFlashLoanHandler.OpenFlashLoanParams memory params = AaveFlashLoanHandler.OpenFlashLoanParams({
            collateralToken: collateralToken,
            collateralAmount: collateralAmount,
            borrowToken: borrowToken,
            borrowAmount: borrowAmount,
            strataxFeeAmount: strataxFeeAmount,
            swapData: swapData,
            minReturnAmount: minReturnAmount
        });

        bytes memory encodedParams = abi.encode(OperationType.OPEN, msg.sender, params);
        aavePool.flashLoanSimple(address(this), collateralToken, flashLoanAmount, encodedParams, 0);
    }

    function _adjustPositionLeverageCommon(uint256 desiredLeverage, bytes memory swapData, uint256 minReturnAmount)
        internal
    {
        require(!isBurned, "Position is burned, only unwinding allowed");
        require(desiredLeverage >= StrataxCalculations.LEVERAGE_PRECISION, "Leverage must be >= 1x");

        uint256 currentLeverage = getCurrentLeverage();
        require(currentLeverage != desiredLeverage, "Already at target leverage");

        if (currentLeverage < desiredLeverage) {
            _createLeveragedPositionCommon(desiredLeverage, 0, swapData, minReturnAmount);
            return;
        }

        uint256 positionUsdValue = getPositionUsdValue();
        require(positionUsdValue > 0, "No active equity");

        uint256 leverageDelta = currentLeverage - desiredLeverage;
        uint256 debtRepayUsdValue = (positionUsdValue * leverageDelta) / StrataxCalculations.LEVERAGE_PRECISION;

        uint256 feeBps = flashLoanFeeBps + IFeeCollector(feeCollector).strataxFee();
        uint256 denominator = StrataxCalculations.FLASHLOAN_FEE_PREC * StrataxCalculations.LEVERAGE_PRECISION;

        if (desiredLeverage > StrataxCalculations.LEVERAGE_PRECISION && feeBps > 0) {
            uint256 feeAdjustment = feeBps * (desiredLeverage - StrataxCalculations.LEVERAGE_PRECISION);
            require(feeAdjustment < denominator, "Target leverage too high");
            denominator = denominator - feeAdjustment;
        }

        debtRepayUsdValue =
            (debtRepayUsdValue
                    * StrataxCalculations.FLASHLOAN_FEE_PREC
                    * StrataxCalculations.LEVERAGE_PRECISION
                    + denominator
                    - 1) / denominator;

        uint256 borrowTokenPriceUsd = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        require(borrowTokenPriceUsd > 0, "Invalid borrow token price");

        uint256 debtToRepay =
            (debtRepayUsdValue * (10 ** borrowTokenDecimals) + borrowTokenPriceUsd - 1) / borrowTokenPriceUsd;
        require(debtToRepay > 0, "Debt repay too small");

        (uint256 collateralToWithdraw, uint256 debtAmount,) = calculateUnwindParams(debtToRepay);
        _unwindPositionCommon(collateralToWithdraw, debtAmount, swapData, minReturnAmount);
    }

    function _unwindPositionCommon(
        uint256 collateralToWithdraw,
        uint256 debtAmount,
        bytes memory swapData,
        uint256 minReturnAmount
    ) internal {
        AaveFlashLoanHandler.UnwindFlashLoanParams memory params =
            AaveFlashLoanHandler.UnwindFlashLoanParams({
                collateralToken: collateralToken,
                collateralToWithdraw: collateralToWithdraw,
                debtToken: borrowToken,
                debtAmount: debtAmount,
                swapData: swapData,
                minReturnAmount: minReturnAmount
            });

        bytes memory encodedParams = abi.encode(OperationType.UNWIND, msg.sender, params);
        aavePool.flashLoanSimple(address(this), borrowToken, debtAmount, encodedParams, 0);
    }
}
