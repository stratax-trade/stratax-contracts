// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPyth} from "./interfaces/external/IPyth.sol";

/**
 * @title StrataxTokenSale
 * @notice Upgradeable token sale contract that prices STRATAX in USD and accepts only whitelisted payment tokens.
 * @dev STRATAX price is configured in USD with 8 decimals.
 */
contract StrataxTokenSale is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant USD_PRICE_DECIMALS = 8;
    uint256 public constant USD_PRICE_PRECISION = 10 ** USD_PRICE_DECIMALS;

    // tokenomics (community-first)
    uint256 public constant TOKENOMICS_TOTAL_SUPPLY = 100_000_000;
    uint256 public constant PUBLIC_SALE_ALLOCATION_BPS = 2_000; // 20%
    uint256 public constant BPS = 10_000;
    uint256 public constant PUBLIC_SALE_TGE_BPS = 2_500; // 25% immediate unlock
    uint256 public constant PUBLIC_SALE_VESTING_DURATION = 270 days; // 9 months linear vesting

    struct PaymentTokenConfig {
        bool isWhitelisted;
        bytes32 pythPriceId;
        uint256 maxPriceAge;
    }

    address public strataxToken;
    address public paymentRecipient;
    address public pyth;
    uint256 public saleStartTimestamp;
    uint256 public totalPublicSaleSold;
    bool public salePaused;
    bool public saleClosed;

    /// @notice STRATAX USD price with 8 decimals. Example: $0.15 => 15_000_000.
    uint256 public strataxPriceUsd;

    mapping(address => PaymentTokenConfig) public paymentTokenConfigs;
    mapping(address => uint256) public totalPurchased;
    mapping(address => uint256) public totalVestedAllocation;
    mapping(address => uint256) public vestedClaimed;

    event StrataxPriceUpdated(uint256 oldPriceUsd, uint256 newPriceUsd);
    event PaymentRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event PythUpdated(address indexed oldPyth, address indexed newPyth);
    event PaymentTokenWhitelisted(address indexed token, bytes32 indexed priceId, uint256 maxPriceAge);
    event PaymentTokenRemoved(address indexed token);
    event SalePaused(address indexed by);
    event SaleUnpaused(address indexed by);
    event SaleClosed(address indexed by);
    event TokensPurchased(
        address indexed buyer,
        address indexed paymentToken,
        uint256 paymentAmount,
        uint256 paymentTokenPriceUsd,
        uint256 strataxOut
    );
    event VestedTokensClaimed(address indexed buyer, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the token sale contract.
     * @param owner_ Contract owner.
     * @param strataxToken_ STRATAX token address.
     * @param pyth_ Pyth contract address.
     * @param paymentRecipient_ Address that receives payment tokens.
     * @param strataxPriceUsd_ STRATAX USD price with 8 decimals.
     */
    function initialize(
        address owner_,
        address strataxToken_,
        address pyth_,
        address paymentRecipient_,
        uint256 strataxPriceUsd_
    ) external initializer {
        require(owner_ != address(0), "Invalid owner");
        require(strataxToken_ != address(0), "Invalid STRATAX token");
        require(pyth_ != address(0), "Invalid Pyth address");
        require(paymentRecipient_ != address(0), "Invalid recipient");
        require(strataxPriceUsd_ > 0, "Invalid STRATAX price");

        __Ownable_init(owner_);

        strataxToken = strataxToken_;
        pyth = pyth_;
        paymentRecipient = paymentRecipient_;
        strataxPriceUsd = strataxPriceUsd_;
        saleStartTimestamp = block.timestamp;
    }

    /**
     * @notice Owner sets the STRATAX token price in USD (8 decimals).
     */
    function setStrataxPriceUsd(uint256 newPriceUsd) external onlyOwner {
        require(newPriceUsd > 0, "Invalid STRATAX price");
        uint256 oldPrice = strataxPriceUsd;
        strataxPriceUsd = newPriceUsd;
        emit StrataxPriceUpdated(oldPrice, newPriceUsd);
    }

    /**
     * @notice Owner updates the payment recipient address.
     */
    function setPaymentRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        address oldRecipient = paymentRecipient;
        paymentRecipient = newRecipient;
        emit PaymentRecipientUpdated(oldRecipient, newRecipient);
    }

    /**
     * @notice Owner updates Pyth contract address.
     */
    function setPyth(address newPyth) external onlyOwner {
        require(newPyth != address(0), "Invalid Pyth address");
        address oldPyth = pyth;
        pyth = newPyth;
        emit PythUpdated(oldPyth, newPyth);
    }

    /**
     * @notice Owner pauses purchases.
     */
    function pauseSale() external onlyOwner {
        require(!saleClosed, "Sale is closed");
        require(!salePaused, "Sale already paused");
        salePaused = true;
        emit SalePaused(msg.sender);
    }

    /**
     * @notice Owner unpauses purchases.
     */
    function unpauseSale() external onlyOwner {
        require(!saleClosed, "Sale is closed");
        require(salePaused, "Sale not paused");
        salePaused = false;
        emit SaleUnpaused(msg.sender);
    }

    /**
     * @notice Owner permanently closes purchases.
     * @dev Closing is irreversible and does not affect vested-claim functionality.
     */
    function closeSale() external onlyOwner {
        require(!saleClosed, "Sale already closed");
        saleClosed = true;
        salePaused = true;
        emit SaleClosed(msg.sender);
    }

    /**
     * @notice Owner whitelists or updates a payment token config.
     */
    function whitelistPaymentToken(address token, bytes32 priceId, uint256 maxPriceAge) external onlyOwner {
        require(token != address(0), "Invalid payment token");
        require(maxPriceAge > 0, "Invalid max price age");

        paymentTokenConfigs[token] =
            PaymentTokenConfig({isWhitelisted: true, pythPriceId: priceId, maxPriceAge: maxPriceAge});

        emit PaymentTokenWhitelisted(token, priceId, maxPriceAge);
    }

    /**
     * @notice Owner removes a payment token from whitelist.
     */
    function removePaymentToken(address token) external onlyOwner {
        require(paymentTokenConfigs[token].isWhitelisted, "Token not whitelisted");
        delete paymentTokenConfigs[token];
        emit PaymentTokenRemoved(token);
    }

    /**
     * @notice Quotes STRATAX output for a payment token amount using latest Pyth price.
     */
    function quote(address paymentToken, uint256 paymentAmount) external view returns (uint256 strataxOut) {
        require(paymentAmount > 0, "Invalid payment amount");

        PaymentTokenConfig memory cfg = paymentTokenConfigs[paymentToken];
        require(cfg.isWhitelisted, "Payment token not whitelisted");

        IPyth.Price memory priceData = IPyth(pyth).getPriceNoOlderThan(cfg.pythPriceId, cfg.maxPriceAge);
        uint256 paymentTokenPriceUsd = _normalizePythPriceToUsdE8(priceData.price, priceData.expo);

        return _calculateStrataxOut(paymentToken, paymentAmount, paymentTokenPriceUsd);
    }

    /**
     * @notice Purchases STRATAX using a whitelisted payment token.
     * @param paymentToken Whitelisted token used for payment.
     * @param paymentAmount Amount of payment token sent from buyer.
     * @param minStrataxOut Minimum STRATAX output for slippage protection.
     * @param pythUpdateData Optional update data for Pyth; pass empty if prices are already fresh.
     */
    function buy(address paymentToken, uint256 paymentAmount, uint256 minStrataxOut, bytes[] calldata pythUpdateData)
        external
        payable
        nonReentrant
        returns (uint256 strataxOut)
    {
        require(!saleClosed, "Sale is closed");
        require(!salePaused, "Sale is paused");
        require(paymentAmount > 0, "Invalid payment amount");

        PaymentTokenConfig memory cfg = paymentTokenConfigs[paymentToken];
        require(cfg.isWhitelisted, "Payment token not whitelisted");

        uint256 updateFee;
        if (pythUpdateData.length > 0) {
            updateFee = IPyth(pyth).getUpdateFee(pythUpdateData);
            require(msg.value >= updateFee, "Insufficient update fee");
            IPyth(pyth).updatePriceFeeds{value: updateFee}(pythUpdateData);
        }

        IPyth.Price memory priceData = IPyth(pyth).getPriceNoOlderThan(cfg.pythPriceId, cfg.maxPriceAge);
        uint256 paymentTokenPriceUsd = _normalizePythPriceToUsdE8(priceData.price, priceData.expo);

        strataxOut = _calculateStrataxOut(paymentToken, paymentAmount, paymentTokenPriceUsd);
        require(strataxOut >= minStrataxOut, "Slippage: insufficient STRATAX out");
        require(totalPublicSaleSold + strataxOut <= getPublicSaleSupplyCap(), "Public sale allocation exceeded");

        uint256 immediateUnlock = (strataxOut * PUBLIC_SALE_TGE_BPS) / BPS;
        uint256 vestedPortion = strataxOut - immediateUnlock;
        require(IERC20(strataxToken).balanceOf(address(this)) >= immediateUnlock, "Insufficient sale inventory");

        IERC20(paymentToken).safeTransferFrom(msg.sender, paymentRecipient, paymentAmount);
        if (immediateUnlock > 0) {
            IERC20(strataxToken).safeTransfer(msg.sender, immediateUnlock);
        }

        totalPublicSaleSold += strataxOut;
        totalPurchased[msg.sender] += strataxOut;
        totalVestedAllocation[msg.sender] += vestedPortion;

        if (msg.value > updateFee) {
            (bool refunded,) = payable(msg.sender).call{value: msg.value - updateFee}("");
            require(refunded, "Refund failed");
        }

        emit TokensPurchased(msg.sender, paymentToken, paymentAmount, paymentTokenPriceUsd, strataxOut);
    }

    /**
     * @notice Claims vested public sale tokens (75% linear unlock over 270 days from sale start)
     */
    function claimVestedTokens() external nonReentrant returns (uint256 claimedAmount) {
        claimedAmount = getClaimableVested(msg.sender);
        require(claimedAmount > 0, "No vested tokens claimable");
        require(IERC20(strataxToken).balanceOf(address(this)) >= claimedAmount, "Insufficient sale inventory");

        vestedClaimed[msg.sender] += claimedAmount;
        IERC20(strataxToken).safeTransfer(msg.sender, claimedAmount);

        emit VestedTokensClaimed(msg.sender, claimedAmount);
    }

    /**
     * @notice Returns the total token cap allocated to public sale (20% of 100M supply)
     */
    function getPublicSaleSupplyCap() public view returns (uint256) {
        uint8 strataxDecimals = IERC20Metadata(strataxToken).decimals();
        uint256 tokenomicsSupply = TOKENOMICS_TOTAL_SUPPLY * (10 ** strataxDecimals);
        return (tokenomicsSupply * PUBLIC_SALE_ALLOCATION_BPS) / BPS;
    }

    /**
     * @notice Returns currently claimable vested amount for an account
     */
    function getClaimableVested(address account) public view returns (uint256) {
        uint256 vestedTotalUnlocked = _getUnlockedVested(account);
        uint256 alreadyClaimed = vestedClaimed[account];
        if (vestedTotalUnlocked <= alreadyClaimed) {
            return 0;
        }
        return vestedTotalUnlocked - alreadyClaimed;
    }

    /**
     * @notice Owner can withdraw unsold STRATAX tokens.
     */
    function withdrawUnsoldTokens(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        IERC20(strataxToken).safeTransfer(to, amount);
    }

    function _calculateStrataxOut(address paymentToken, uint256 paymentAmount, uint256 paymentTokenPriceUsd)
        internal
        view
        returns (uint256 strataxOut)
    {
        uint8 paymentDecimals = IERC20Metadata(paymentToken).decimals();
        uint8 strataxDecimals = IERC20Metadata(strataxToken).decimals();

        uint256 paymentUsdValue = (paymentAmount * paymentTokenPriceUsd) / (10 ** paymentDecimals);
        require(paymentUsdValue > 0, "Payment too small");

        strataxOut = (paymentUsdValue * (10 ** strataxDecimals)) / strataxPriceUsd;
    }

    function _getUnlockedVested(address account) internal view returns (uint256 unlocked) {
        uint256 vestedAllocation = totalVestedAllocation[account];
        if (vestedAllocation == 0) {
            return 0;
        }

        uint256 elapsed = block.timestamp - saleStartTimestamp;
        if (elapsed >= PUBLIC_SALE_VESTING_DURATION) {
            return vestedAllocation;
        }

        unlocked = (vestedAllocation * elapsed) / PUBLIC_SALE_VESTING_DURATION;
    }

    function _normalizePythPriceToUsdE8(int64 price, int32 expo) internal pure returns (uint256 normalizedPrice) {
        require(price > 0, "Invalid Pyth price");

        uint256 unsignedPrice = uint256(int256(price));
        int256 expoInt = int256(expo);

        if (expoInt < 0) {
            uint256 negExpo = uint256(-expoInt);
            if (negExpo > USD_PRICE_DECIMALS) {
                normalizedPrice = unsignedPrice / (10 ** (negExpo - USD_PRICE_DECIMALS));
            } else {
                normalizedPrice = unsignedPrice * (10 ** (USD_PRICE_DECIMALS - negExpo));
            }
        } else {
            normalizedPrice = unsignedPrice * (10 ** (USD_PRICE_DECIMALS + uint256(expoInt)));
        }

        require(normalizedPrice > 0, "Normalized price is zero");
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    receive() external payable {}

    /// @notice Storage gap for future upgrades.
    uint256[50] private __gap;
}
