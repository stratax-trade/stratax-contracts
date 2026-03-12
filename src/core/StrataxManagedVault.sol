// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Stratax} from "./Stratax.sol";
import {IStrataxOracle} from "../interfaces/internal/IStrataxOracle.sol";
import {StrataxCalculations} from "../libraries/StrataxCalculations.sol";

/**
 * @title StrataxManagedVault
 * @notice Vault wrapper for one Stratax position that tokenizes user exposure with ERC20 shares.
 * @dev Users deposit the Stratax collateral token and receive vault shares.
 *      A designated manager controls leverage operations on the underlying Stratax position.
 */
contract StrataxManagedVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    Stratax public immutable stratax;
    IERC20 public immutable collateralToken;
    address public manager;

    /// @notice Target leverage with 4-decimal precision (10000 = 1x, 30000 = 3x)
    uint256 public targetLeverage;

    event ManagerUpdated(address indexed oldManager, address indexed newManager);
    event TargetLeverageUpdated(uint256 oldTargetLeverage, uint256 newTargetLeverage);
    event Deposited(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Redeemed(address indexed caller, address indexed receiver, uint256 shares, uint256 assets);
    event LeverageIncreased(uint256 flashLoanAmount, uint256 borrowAmount);
    event PositionUnwound(uint256 debtRepaid, uint256 collateralWithdrawn);

    modifier onlyManager() {
        require(msg.sender == manager, "Not manager");
        _;
    }

    constructor(address stratax_, address manager_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        require(stratax_ != address(0), "Invalid Stratax");
        require(manager_ != address(0), "Invalid manager");

        stratax = Stratax(stratax_);
        collateralToken = IERC20(stratax.collateralToken());
        manager = manager_;
        targetLeverage = StrataxCalculations.LEVERAGE_PRECISION;
    }

    /**
     * @notice Total managed assets in collateral token units.
     * @dev Includes idle collateral in this vault plus Stratax net position value converted from USD to collateral.
     */
    function totalAssets() public view returns (uint256) {
        uint256 idleCollateral = collateralToken.balanceOf(address(this));
        uint256 netPositionUsd = stratax.getPositionUsdValue();

        if (netPositionUsd == 0) {
            return idleCollateral;
        }

        uint256 collateralPriceUsd = IStrataxOracle(stratax.strataxOracle()).getPrice(stratax.collateralToken());
        require(collateralPriceUsd > 0, "Invalid collateral price");

        uint256 deployedCollateralEquivalent =
            (netPositionUsd * (10 ** stratax.collateralTokenDecimals())) / collateralPriceUsd;

        return idleCollateral + deployedCollateralEquivalent;
    }

    function previewDeposit(uint256 assets) public view returns (uint256 shares) {
        require(assets > 0, "Invalid assets");
        uint256 supply = totalSupply();
        uint256 assetsBefore = totalAssets();

        if (supply == 0 || assetsBefore == 0) {
            return assets;
        }

        shares = (assets * supply) / assetsBefore;
    }

    function previewRedeem(uint256 shares) public view returns (uint256 assets) {
        require(shares > 0, "Invalid shares");
        uint256 supply = totalSupply();
        require(supply > 0, "No shares exist");

        assets = (shares * totalAssets()) / supply;
    }

    /**
     * @notice Deposit collateral token and mint vault shares.
     * @dev Deposited collateral is supplied into the underlying Stratax position.
     */
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        require(receiver != address(0), "Invalid receiver");

        shares = previewDeposit(assets);
        require(shares > 0, "Zero shares");

        collateralToken.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        collateralToken.forceApprove(address(stratax), assets);
        stratax.supplyCollateral(assets);

        emit Deposited(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Redeem vault shares for collateral token.
     * @dev Withdraws collateral from Stratax when idle balance is insufficient.
     */
    function redeem(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        require(receiver != address(0), "Invalid receiver");

        assets = previewRedeem(shares);
        require(assets > 0, "Zero assets");

        _burn(msg.sender, shares);

        uint256 idleCollateral = collateralToken.balanceOf(address(this));
        if (idleCollateral < assets) {
            uint256 needed = assets - idleCollateral;
            stratax.withdrawCollateral(needed);
        }

        collateralToken.safeTransfer(receiver, assets);

        emit Redeemed(msg.sender, receiver, shares, assets);
    }

    function setManager(address newManager) external onlyManager {
        require(newManager != address(0), "Invalid manager");
        address oldManager = manager;
        manager = newManager;
        emit ManagerUpdated(oldManager, newManager);
    }

    function setTargetLeverage(uint256 newTargetLeverage) external onlyManager {
        require(newTargetLeverage >= StrataxCalculations.LEVERAGE_PRECISION, "Target leverage < 1x");
        uint256 oldTarget = targetLeverage;
        targetLeverage = newTargetLeverage;
        emit TargetLeverageUpdated(oldTarget, newTargetLeverage);
    }

    /**
     * @notice Increase leverage toward target leverage using available free collateral.
     * @dev Manager must provide 1inch swap data for borrow->collateral leg.
     */
    function increaseLeverageToTarget(bytes calldata oneInchSwapData, uint256 minReturnAmount)
        external
        onlyManager
        nonReentrant
    {
        uint256 currentLeverage = stratax.getCurrentLeverage();
        require(currentLeverage < targetLeverage, "Already at/above target leverage");

        (uint256 flashLoanAmount, uint256 borrowAmount) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: targetLeverage, collateralAmount: 0, collateralTokenPrice: 0, borrowTokenPrice: 0
            })
        );

        stratax.createLeveragedPosition(flashLoanAmount, 0, borrowAmount, oneInchSwapData, minReturnAmount);

        emit LeverageIncreased(flashLoanAmount, borrowAmount);
    }

    /**
     * @notice Unwind part or all of the position.
     * @param debtToRepay Desired debt amount to repay. Use type(uint256).max to fully unwind.
     * @param oneInchSwapData 1inch swap calldata for collateral->borrow token leg.
     * @param minReturnAmount Minimum swap return in borrow token units.
     */
    function unwindPosition(uint256 debtToRepay, bytes calldata oneInchSwapData, uint256 minReturnAmount)
        external
        onlyManager
        nonReentrant
    {
        (uint256 collateralToWithdraw, uint256 debtAmount,) = stratax.calculateUnwindParams(debtToRepay);
        stratax.unwindPosition(collateralToWithdraw, debtAmount, oneInchSwapData, minReturnAmount);

        emit PositionUnwound(debtAmount, collateralToWithdraw);
    }
}
