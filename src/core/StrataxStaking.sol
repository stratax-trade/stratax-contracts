// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

interface IFeeCollector {
    function collectStakerRewardsForAllAssets() external;
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

    uint256 public constant BPS = 10_000;
    uint256 public constant ACC_PRECISION = 1e24;

    address public feeCollector;

    // STRATAX emission yield state.
    uint256 public strataxEmissionRatePerSecond;
    uint256 public strataxEmissionRemaining;
    uint256 public lastEmissionTimestamp;

    // Reward tokens distributed via claim (expected from FeeCollector).
    EnumerableSet.AddressSet private _rewardTokens;
    mapping(address => uint256) public accRewardPerShare;
    mapping(address => uint256) public undistributedRewards;
    mapping(address => mapping(address => uint256)) public userRewardDebt;
    mapping(address => mapping(address => uint256)) public userClaimable;

    event FeeCollectorUpdated(address indexed oldFeeCollector, address indexed newFeeCollector);
    event StrataxEmissionRateUpdated(uint256 oldRate, uint256 newRate);
    event EmissionFunded(uint256 amount, uint256 newRemaining);
    event ProtocolRewardsSynced(address indexed caller);
    event RewardDistributed(address indexed token, uint256 amount);
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

    function setFeeCollector(address newFeeCollector) external onlyOwner {
        require(newFeeCollector != address(0), "Invalid fee collector");
        address old = feeCollector;
        feeCollector = newFeeCollector;
        emit FeeCollectorUpdated(old, newFeeCollector);
    }

    function setStrataxEmissionRatePerSecond(uint256 newRate) external onlyOwner {
        _accrueStrataxEmission();
        uint256 oldRate = strataxEmissionRatePerSecond;
        strataxEmissionRatePerSecond = newRate;
        emit StrataxEmissionRateUpdated(oldRate, newRate);
    }

    /**
     * @notice Owner deposits STRATAX to fund future emission yield.
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

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        _accrueStrataxEmission();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        _accrueStrataxEmission();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _accrueStrataxEmission();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _accrueStrataxEmission();
        return super.redeem(shares, receiver, owner_);
    }

    /**
     * @dev Keep reward accounting in sync when shares are transferred/minted/burned.
     */
    function _update(address from, address to, uint256 value) internal override {
        _accrueStrataxEmission();
        _distributeAllUndistributed();

        if (from != address(0)) {
            _accrueUser(from);
        }
        if (to != address(0) && to != from) {
            _accrueUser(to);
        }

        super._update(from, to, value);

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
        _accrueStrataxEmission();
        _distributeAllUndistributed();

        address[] memory tokens = IFeeCollector(feeCollector).getAllTrackedFeeTokens();
        uint256 len = tokens.length;

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

        emit ProtocolRewardsSynced(msg.sender);
    }

    function claimAllRewards() external nonReentrant {
        _accrueStrataxEmission();
        _distributeAllUndistributed();
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

    function claimReward(address token) external nonReentrant {
        _accrueStrataxEmission();
        _distributeAllUndistributed();
        _accrueUser(msg.sender);
        _resetUserDebt(msg.sender);

        uint256 amount = userClaimable[msg.sender][token];
        require(amount > 0, "No claimable rewards");
        userClaimable[msg.sender][token] = 0;

        IERC20(token).safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, token, amount);
    }

    function pendingReward(address account, address token) external view returns (uint256) {
        uint256 shares = balanceOf(account);
        uint256 accrued = (shares * accRewardPerShare[token]) / ACC_PRECISION;
        uint256 debt = userRewardDebt[account][token];
        uint256 pending = accrued > debt ? accrued - debt : 0;
        return userClaimable[account][token] + pending;
    }

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
