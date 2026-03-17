// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Stratax} from "./Stratax.sol";
import {IFeeCollector} from "../interfaces/internal/IFeeCollector.sol";
import {IStrataxOracle} from "../interfaces/internal/IStrataxOracle.sol";
import {StrataxCalculations} from "../libraries/StrataxCalculations.sol";

/**
 * @title StrataxManagedVault
 * @notice Vault wrapper for one Stratax position that tokenizes user exposure with ERC20 shares.
 * @dev Users deposit the Stratax collateral token and receive vault shares.
 *      A designated manager controls leverage operations on the underlying Stratax position.
 */
contract StrataxManagedVault is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct WithdrawalRequest {
        address owner;
        address receiver;
        uint256 shares;
        bool processed;
        bool canceled;
    }

    Stratax public immutable stratax;
    IERC20 public immutable collateralToken;
    address public manager;
    bool public paused;
    bool public deactivated;

    /// @notice Target leverage with 4-decimal precision (10000 = 1x, 30000 = 3x)
    uint256 public targetLeverage;

    uint256 public nextWithdrawalRequestId;
    uint256 public nextWithdrawalToProcess;
    uint256 public totalPendingWithdrawals;
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;

    event ManagerUpdated(address indexed oldManager, address indexed newManager);
    event TargetLeverageUpdated(uint256 oldTargetLeverage, uint256 newTargetLeverage);
    event Deposited(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Redeemed(address indexed caller, address indexed receiver, uint256 shares, uint256 assets);
    event LeverageIncreased(uint256 flashLoanAmount, uint256 borrowAmount);
    event PositionUnwound(uint256 debtRepaid, uint256 collateralWithdrawn);
    event PauseUpdated(bool isPaused);
    event VaultDeactivated();
    event WithdrawalRequested(
        uint256 indexed requestId, address indexed owner, address indexed receiver, uint256 shares
    );
    event WithdrawalProcessed(uint256 indexed requestId, address indexed receiver, uint256 assets);
    event WithdrawalCanceled(uint256 indexed requestId, address indexed owner, uint256 shares);

    function _effectiveTotalSupply() internal view returns (uint256) {
        return totalSupply() + totalPendingWithdrawals;
    }

    modifier onlyManager() {
        require(msg.sender == manager, "Not manager");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Vault is paused");
        _;
    }

    modifier whenNotDeactivated() {
        require(!deactivated, "Vault is deactivated");
        _;
    }

    constructor(address stratax_, address manager_, string memory name_, string memory symbol_)
        ERC4626(IERC20(Stratax(stratax_).collateralToken()))
        ERC20(name_, symbol_)
    {
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
    function totalAssets() public view override returns (uint256) {
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

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = _effectiveTotalSupply();
        uint256 currentTotalAssets = totalAssets();

        if (supply == 0 || currentTotalAssets == 0) {
            return assets;
        }

        return assets.mulDiv(supply, currentTotalAssets, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = _effectiveTotalSupply();
        uint256 currentTotalAssets = totalAssets();

        if (supply == 0 || currentTotalAssets == 0) {
            return shares;
        }

        return shares.mulDiv(currentTotalAssets, supply, rounding);
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused || deactivated) {
            return 0;
        }
        return super.maxDeposit(receiver);
    }

    function maxMint(address receiver) public view override returns (uint256) {
        if (paused || deactivated) {
            return 0;
        }
        return super.maxMint(receiver);
    }

    /**
     * @notice Deposit collateral token and mint vault shares.
     * @dev Deposited collateral is supplied into the underlying Stratax position.
     */
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        whenNotDeactivated
        returns (uint256 shares)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        whenNotDeactivated
        returns (uint256 assets)
    {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        return super.redeem(shares, receiver, owner);
    }

    // Convenience wrapper retained for existing integrations.
    function redeem(uint256 shares, address receiver) external returns (uint256 assets) {
        return redeem(shares, receiver, msg.sender);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        require(receiver != address(0), "Invalid receiver");
        require(shares > 0, "Zero shares");

        collateralToken.safeTransferFrom(caller, address(this), assets);
        _mint(receiver, shares);

        collateralToken.forceApprove(address(stratax), assets);
        stratax.supplyCollateral(assets);

        emit Deposit(caller, receiver, assets, shares);
        emit Deposited(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        require(receiver != address(0), "Invalid receiver");

        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        _burn(owner, shares);

        uint256 idleCollateral = collateralToken.balanceOf(address(this));
        if (idleCollateral < assets) {
            require(!paused && !deactivated, "Use withdraw queue");
            uint256 needed = assets - idleCollateral;
            stratax.withdrawCollateral(needed);
        }

        collateralToken.safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
        emit Redeemed(caller, receiver, shares, assets);
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

    function setPause(bool isPaused) external onlyManager {
        require(!deactivated || isPaused, "Vault is deactivated");
        paused = isPaused;
        emit PauseUpdated(isPaused);
    }

    function deactivate() external onlyManager {
        require(!deactivated, "Already deactivated");
        deactivated = true;
        paused = true;
        emit PauseUpdated(true);
        emit VaultDeactivated();
    }

    /**
     * @notice Increase leverage toward target leverage using available free collateral.
     * @dev Manager must provide 1inch swap data for borrow->collateral leg.
     */
    function increaseLeverageToTarget(bytes calldata oneInchSwapData, uint256 minReturnAmount)
        external
        onlyManager
        nonReentrant
        whenNotPaused
        whenNotDeactivated
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

    /**
     * @notice Queue a redeem request to be processed when idle collateral is available.
     * @dev Burns shares immediately and records an assets claim in FIFO queue order.
     */
    function requestWithdrawal(uint256 shares, address receiver) external nonReentrant returns (uint256 requestId) {
        require(receiver != address(0), "Invalid receiver");
        require(shares > 0, "Invalid shares");

        _burn(msg.sender, shares);
        totalPendingWithdrawals += shares;

        requestId = nextWithdrawalRequestId;
        nextWithdrawalRequestId++;

        withdrawalRequests[requestId] = WithdrawalRequest({
            owner: msg.sender, receiver: receiver, shares: shares, processed: false, canceled: false
        });

        emit WithdrawalRequested(requestId, msg.sender, receiver, shares);
    }

    /**
     * @notice Cancel a pending withdrawal request and restore shares to the requester.
     * @param requestId Withdrawal request ID.
     * @return restoredShares Number of shares minted back to the requester.
     */
    function cancelWithdrawalRequest(uint256 requestId) external nonReentrant returns (uint256 restoredShares) {
        WithdrawalRequest storage request = withdrawalRequests[requestId];

        require(request.owner == msg.sender, "Not request owner");
        require(!request.processed, "Already processed");
        require(!request.canceled, "Already canceled");

        request.canceled = true;
        restoredShares = request.shares;
        totalPendingWithdrawals -= restoredShares;

        _mint(msg.sender, restoredShares);

        emit WithdrawalCanceled(requestId, msg.sender, restoredShares);
    }

    /**
     * @notice Process queued withdrawals in FIFO order using currently idle collateral.
     * @param maxRequests Maximum number of queue entries to attempt processing.
     * @return processedCount Number of requests processed in this call.
     */
    function processWithdrawalQueue(uint256 maxRequests)
        external
        onlyManager
        nonReentrant
        returns (uint256 processedCount)
    {
        require(maxRequests > 0, "Invalid max requests");

        uint256 currentId = nextWithdrawalToProcess;
        uint256 finalId = nextWithdrawalRequestId;
        uint256 idleCollateral = collateralToken.balanceOf(address(this));

        while (processedCount < maxRequests && currentId < finalId) {
            WithdrawalRequest storage request = withdrawalRequests[currentId];

            if (request.processed || request.canceled) {
                currentId++;
                continue;
            }

            uint256 effectiveSupply = _effectiveTotalSupply();
            require(effectiveSupply > 0, "No shares exist");

            uint256 requestAssets = (request.shares * totalAssets()) / effectiveSupply;
            require(requestAssets > 0, "Zero assets");

            if (idleCollateral < requestAssets) {
                break;
            }

            request.processed = true;
            totalPendingWithdrawals -= request.shares;
            idleCollateral -= requestAssets;
            collateralToken.safeTransfer(request.receiver, requestAssets);

            emit WithdrawalProcessed(currentId, request.receiver, requestAssets);

            currentId++;
            processedCount++;
        }

        nextWithdrawalToProcess = currentId;
    }

    /**
     * @notice Unwind position down toward configured target leverage.
     * @dev Computes required debt repayment from current leverage/equity and executes a partial unwind.
     * @param oneInchSwapData 1inch swap calldata for collateral->borrow token leg.
     * @param minReturnAmount Minimum swap return in borrow token units.
     */
    function unwindPositionToTarget(bytes calldata oneInchSwapData, uint256 minReturnAmount)
        external
        onlyManager
        nonReentrant
    {
        uint256 currentLeverage = stratax.getCurrentLeverage();
        require(currentLeverage > targetLeverage, "Already at/below target leverage");

        uint256 positionUsdValue = stratax.getPositionUsdValue();
        require(positionUsdValue > 0, "No active equity");

        // Base debt value to repay in USD terms before accounting for unwind fees.
        uint256 leverageDelta = currentLeverage - targetLeverage;
        uint256 debtRepayUsdValue = (positionUsdValue * leverageDelta) / StrataxCalculations.LEVERAGE_PRECISION;

        uint256 feeBps = stratax.flashLoanFeeBps() + IFeeCollector(stratax.feeCollector()).strataxFee();
        uint256 denominator = StrataxCalculations.FLASHLOAN_FEE_PREC * StrataxCalculations.LEVERAGE_PRECISION;

        if (targetLeverage > StrataxCalculations.LEVERAGE_PRECISION && feeBps > 0) {
            uint256 feeAdjustment = feeBps * (targetLeverage - StrataxCalculations.LEVERAGE_PRECISION);
            require(feeAdjustment < denominator, "Target leverage too high");
            denominator -= feeAdjustment;
        }

        // Round up to avoid under-repaying and missing the target due to integer truncation.
        debtRepayUsdValue =
            (debtRepayUsdValue
                    * StrataxCalculations.FLASHLOAN_FEE_PREC
                    * StrataxCalculations.LEVERAGE_PRECISION
                    + denominator
                    - 1) / denominator;

        uint256 borrowTokenPriceUsd = IStrataxOracle(stratax.strataxOracle()).getPrice(stratax.borrowToken());
        require(borrowTokenPriceUsd > 0, "Invalid borrow token price");

        uint256 debtToRepay =
            (debtRepayUsdValue * (10 ** stratax.borrowTokenDecimals()) + borrowTokenPriceUsd - 1) / borrowTokenPriceUsd;
        require(debtToRepay > 0, "Debt repay too small");

        (uint256 collateralToWithdraw, uint256 debtAmount,) = stratax.calculateUnwindParams(debtToRepay);
        stratax.unwindPosition(collateralToWithdraw, debtAmount, oneInchSwapData, minReturnAmount);

        emit PositionUnwound(debtAmount, collateralToWithdraw);
    }
}
