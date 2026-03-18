// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IFeeCollector {
    /// @notice Transfers current staker fee share for all tracked fee tokens to the caller.
    function collectStakerRewardsForAllAssets() external;

    /// @notice Returns all fee tokens currently tracked by the fee collector.
    /// @return tokens Array of tracked fee token addresses.
    function getAllTrackedFeeTokens() external view returns (address[] memory tokens);
}

/**
 * @title StrataxStaking
 * @notice ERC4626 staking vault for STRATAX with multi-token protocol-fee rewards
 * @dev
 * - Vault asset is STRATAX.
 * - Fee rewards (non-STRATAX tokens) are claimable pro-rata by share ownership.
 * - STRATAX emission yield is streamed over time and realized as vault share-price appreciation.
 */
contract StrataxStaking is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Basis points denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Precision used for cumulative reward-per-share accounting.
    uint256 public constant ACC_PRECISION = 1e24;

    /// @notice Fee collector contract used as the source of protocol reward tokens.
    address public feeCollector;

    // STRATAX emission yield state.
    /// @notice STRATAX emitted per second into vault assets.
    uint256 public strataxEmissionRatePerSecond;
    /// @notice Remaining STRATAX emission reserve not yet streamed into vault assets.
    uint256 public strataxEmissionRemaining;
    /// @notice Last timestamp when emission accrual was processed.
    uint256 public lastEmissionTimestamp;
    /// @notice Whether the first mint/deposit has already occurred.
    bool public initialMintCompleted;

    // Reward tokens distributed via claim (expected from FeeCollector).
    EnumerableSet.AddressSet private _rewardTokens;
    /// @notice Accumulated reward-per-share for each reward token.
    mapping(address => uint256) public accRewardPerShare;
    /// @notice Rewards held until there is non-zero share supply to distribute against.
    mapping(address => uint256) public undistributedRewards;
    /// @notice Per-user reward debt snapshot for each reward token.
    mapping(address => mapping(address => uint256)) public userRewardDebt;
    /// @notice Per-user claimable reward balances for each reward token.
    mapping(address => mapping(address => uint256)) public userClaimable;

    /// @notice Storage gap for future upgrades (reserve space for 50 new state variables)
    /// @dev This prevents storage collisions when adding new state variables in upgrades
    uint256[50] private __gap;

    /// @notice Emitted when fee collector address is changed.
    /// @param oldFeeCollector Previous fee collector address.
    /// @param newFeeCollector New fee collector address.
    event FeeCollectorUpdated(address indexed oldFeeCollector, address indexed newFeeCollector);
    /// @notice Emitted when STRATAX emission rate is changed.
    /// @param oldRate Previous emission rate per second.
    /// @param newRate New emission rate per second.
    event StrataxEmissionRateUpdated(uint256 oldRate, uint256 newRate);
    /// @notice Emitted when additional STRATAX emission reserve is funded.
    /// @param amount Amount funded.
    /// @param newRemaining New total emission reserve.
    event EmissionFunded(uint256 amount, uint256 newRemaining);
    /// @notice Emitted when protocol reward sync is manually invoked.
    /// @param caller Address that triggered the sync.
    event ProtocolRewardsSynced(address indexed caller);
    /// @notice Emitted when reward amount is distributed into reward-per-share accounting.
    /// @param token Reward token address.
    /// @param amount Amount distributed.
    event RewardDistributed(address indexed token, uint256 amount);
    /// @notice Emitted when a user claims reward tokens.
    /// @param user Claimer address.
    /// @param token Reward token address.
    /// @param amount Amount transferred to the user.
    event RewardClaimed(address indexed user, address indexed token, uint256 amount);

    constructor(address owner_, IERC20 asset_, address feeCollector_)
        ERC20("Staked STRATAX", "stSTRATAX")
        ERC4626(asset_)
        Ownable(owner_)
    {
        require(address(asset_) != address(0), "Invalid asset");
        require(feeCollector_ != address(0), "Invalid fee collector");
        feeCollector = feeCollector_;
        lastEmissionTimestamp = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the fee collector contract.
     * @param newFeeCollector Address of the new fee collector.
     */
    function setFeeCollector(address newFeeCollector) external onlyOwner {
        require(newFeeCollector != address(0), "Invalid fee collector");
        address old = feeCollector;
        feeCollector = newFeeCollector;
        emit FeeCollectorUpdated(old, newFeeCollector);
    }

    /**
     * @notice Sets STRATAX emission rate per second.
     * @param newRate New emission rate per second.
     */
    function setStrataxEmissionRatePerSecond(uint256 newRate) external onlyOwner {
        _accrueStrataxEmission();
        uint256 oldRate = strataxEmissionRatePerSecond;
        strataxEmissionRatePerSecond = newRate;
        emit StrataxEmissionRateUpdated(oldRate, newRate);
    }

    /**
     * @notice Owner deposits STRATAX to fund future emission yield.
     * @param amount Amount of STRATAX to add to emission reserve.
     */
    function fundStrataxEmissions(uint256 amount) external onlyOwner {
        require(amount > 0, "Invalid amount");
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        strataxEmissionRemaining += amount;
        emit EmissionFunded(amount, strataxEmissionRemaining);
    }

    /*//////////////////////////////////////////////////////////////
                           VAULT OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns assets backing shares, excluding not-yet-emitted STRATAX reserve.
     */
    function totalAssets() public view override returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        return bal > strataxEmissionRemaining ? bal - strataxEmissionRemaining : 0;
    }

    /**
     * @notice Deposits STRATAX and mints staking shares to receiver.
     * @param assets Amount of STRATAX to deposit.
     * @param receiver Address receiving minted shares.
     * @return shares Amount of shares minted.
     */
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        return super.deposit(assets, receiver);
    }

    /**
     * @notice Mints staking shares to receiver by depositing required STRATAX.
     * @param shares Amount of shares to mint.
     * @param receiver Address receiving minted shares.
     * @return assets Amount of STRATAX deposited.
     */
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        return super.mint(shares, receiver);
    }

    /**
     * @notice Withdraws STRATAX assets by burning owner shares.
     * @param assets Amount of STRATAX to withdraw.
     * @param receiver Address receiving withdrawn assets.
     * @param owner_ Share owner whose shares are burned.
     * @return shares Amount of shares burned.
     */
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        return super.withdraw(assets, receiver, owner_);
    }

    /**
     * @notice Redeems shares for STRATAX assets.
     * @param shares Amount of shares to redeem.
     * @param receiver Address receiving withdrawn assets.
     * @param owner_ Share owner whose shares are burned.
     * @return assets Amount of STRATAX withdrawn.
     */
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        return super.redeem(shares, receiver, owner_);
    }

    /**
     * @dev Keep reward accounting in sync when shares are transferred/minted/burned.
     */
    function _update(address from, address to, uint256 value) internal override {
        // Pull and distribute protocol rewards before any share balance changes
        // so rewards accrued under previous ownership are allocated fairly.
        _syncProtocolRewardsInternal(false);

        if (from != address(0)) {
            _accrueUser(from);
        }
        if (to != address(0) && to != from) {
            _accrueUser(to);
        }

        super._update(from, to, value);

        if (from == address(0) && value > 0 && !initialMintCompleted) {
            initialMintCompleted = true;
        }

        if (from != address(0)) {
            _resetUserDebt(from);
        }
        if (to != address(0) && to != from) {
            _resetUserDebt(to);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PROTOCOL REWARDS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pulls staker rewards from FeeCollector and distributes them to stakers.
     * @dev Expects FeeCollector to transfer reward tokens to this contract.
     */
    function syncProtocolRewards() external nonReentrant {
        _syncProtocolRewardsInternal(true);
    }

    /**
     * @notice Claims all currently claimable rewards across all tracked reward tokens.
     */
    function claimAllRewards() external nonReentrant {
        _syncProtocolRewardsInternal(false);
        _accrueUser(msg.sender);
        _resetUserDebt(msg.sender);

        uint256 len = _rewardTokens.length();
        for (uint256 i = 0; i < len; i++) {
            address token = _rewardTokens.at(i);
            uint256 amount = userClaimable[msg.sender][token];
            if (amount == 0) {
                continue;
            }
            userClaimable[msg.sender][token] = 0;
            IERC20(token).safeTransfer(msg.sender, amount);
            emit RewardClaimed(msg.sender, token, amount);
        }
    }

    /**
     * @notice Claims currently claimable amount for a specific reward token.
     * @param token Reward token to claim.
     */
    function claimReward(address token) external nonReentrant {
        _syncProtocolRewardsInternal(false);
        _accrueUser(msg.sender);
        _resetUserDebt(msg.sender);

        uint256 amount = userClaimable[msg.sender][token];
        require(amount > 0, "No claimable rewards");
        userClaimable[msg.sender][token] = 0;

        IERC20(token).safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, token, amount);
    }

    /**
     * @notice Returns account's pending amount for a reward token.
     * @param account Account to query.
     * @param token Reward token address.
     * @return Pending reward amount claimable for the account.
     */
    function pendingReward(address account, address token) external view returns (uint256) {
        uint256 shares = balanceOf(account);
        uint256 accrued = (shares * accRewardPerShare[token]) / ACC_PRECISION;
        uint256 debt = userRewardDebt[account][token];
        uint256 pending = accrued > debt ? accrued - debt : 0;
        return userClaimable[account][token] + pending;
    }

    /**
     * @notice Returns all reward tokens currently tracked by the staking vault.
     * @return tokens Array of reward token addresses.
     */
    function getRewardTokens() external view returns (address[] memory tokens) {
        uint256 len = _rewardTokens.length();
        tokens = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            tokens[i] = _rewardTokens.at(i);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _accrueStrataxEmission() internal {
        uint256 current = block.timestamp;
        uint256 last = lastEmissionTimestamp;
        if (current <= last) {
            return;
        }

        lastEmissionTimestamp = current;

        // Do not consume emission while there are no stakers.
        uint256 supply = totalSupply();
        if (supply == 0 || strataxEmissionRemaining == 0 || strataxEmissionRatePerSecond == 0) {
            return;
        }

        uint256 elapsed = current - last;
        uint256 toEmit = elapsed * strataxEmissionRatePerSecond;
        if (toEmit > strataxEmissionRemaining) {
            toEmit = strataxEmissionRemaining;
        }

        // Emitted amount becomes part of totalAssets by reducing reserved emission balance.
        strataxEmissionRemaining -= toEmit;
    }

    function _syncProtocolRewardsInternal(bool emitEvent) internal {
        _accrueStrataxEmission();
        _distributeAllUndistributed();

        address[] memory tokens = IFeeCollector(feeCollector).getAllTrackedFeeTokens();
        uint256 len = tokens.length;
        if (len == 0) {
            if (emitEvent) {
                emit ProtocolRewardsSynced(msg.sender);
            }
            return;
        }

        uint256[] memory beforeBalances = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            beforeBalances[i] = IERC20(tokens[i]).balanceOf(address(this));
        }

        IFeeCollector(feeCollector).collectStakerRewardsForAllAssets();

        for (uint256 i = 0; i < len; i++) {
            address token = tokens[i];
            uint256 afterBalance = IERC20(token).balanceOf(address(this));
            if (afterBalance <= beforeBalances[i]) {
                continue;
            }

            uint256 received = afterBalance - beforeBalances[i];
            if (!_rewardTokens.contains(token)) {
                _rewardTokens.add(token);
            }
            _distributeReward(token, received);
        }

        if (emitEvent) {
            emit ProtocolRewardsSynced(msg.sender);
        }
    }

    /**
     * @dev Force 1:1 conversion only for the very first mint/deposit to avoid bootstrap skew.
     * After the first mint, fallback to standard ERC4626 conversion logic.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        if (!initialMintCompleted) {
            return assets;
        }
        return super._convertToShares(assets, rounding);
    }

    /**
     * @dev Mirrors _convertToShares bootstrap behavior in the reverse conversion direction.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        if (!initialMintCompleted) {
            return shares;
        }
        return super._convertToAssets(shares, rounding);
    }

    function _distributeReward(address token, uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        uint256 supply = totalSupply();
        if (supply == 0) {
            undistributedRewards[token] += amount;
            return;
        }

        accRewardPerShare[token] += (amount * ACC_PRECISION) / supply;
        emit RewardDistributed(token, amount);
    }

    function _distributeAllUndistributed() internal {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return;
        }

        uint256 len = _rewardTokens.length();
        for (uint256 i = 0; i < len; i++) {
            address token = _rewardTokens.at(i);
            uint256 amount = undistributedRewards[token];
            if (amount == 0) {
                continue;
            }
            undistributedRewards[token] = 0;
            accRewardPerShare[token] += (amount * ACC_PRECISION) / supply;
            emit RewardDistributed(token, amount);
        }
    }

    function _accrueUser(address account) internal {
        uint256 shares = balanceOf(account);
        uint256 len = _rewardTokens.length();

        for (uint256 i = 0; i < len; i++) {
            address token = _rewardTokens.at(i);
            uint256 accrued = (shares * accRewardPerShare[token]) / ACC_PRECISION;
            uint256 debt = userRewardDebt[account][token];
            if (accrued > debt) {
                userClaimable[account][token] += accrued - debt;
            }
        }
    }

    function _resetUserDebt(address account) internal {
        uint256 shares = balanceOf(account);
        uint256 len = _rewardTokens.length();

        for (uint256 i = 0; i < len; i++) {
            address token = _rewardTokens.at(i);
            userRewardDebt[account][token] = (shares * accRewardPerShare[token]) / ACC_PRECISION;
        }
    }
}
