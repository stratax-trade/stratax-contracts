// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StrataxTokenSale} from "../../src/StrataxTokenSale.sol";
import {IPyth} from "../../src/interfaces/external/IPyth.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _customDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _customDecimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }
}

contract MockPyth is IPyth {
    mapping(bytes32 => Price) internal _prices;
    uint256 public updateFee;

    function setPrice(bytes32 id, int64 price, int32 expo) external {
        _prices[id] = Price({price: price, conf: 0, expo: expo, publishTime: block.timestamp});
    }

    function setUpdateFee(uint256 newFee) external {
        updateFee = newFee;
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory) {
        Price memory p = _prices[id];
        require(p.publishTime != 0, "price not set");
        require(block.timestamp - p.publishTime <= age, "stale price");
        return p;
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256 feeAmount) {
        return updateFee;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {
        require(msg.value >= updateFee, "insufficient pyth fee");
    }
}

contract StrataxTokenSaleUnitTest is Test {
    uint256 internal constant STRATAX_PRICE_USD = 20_000_000; // $0.20 (8 decimals)
    bytes32 internal constant USDC_PRICE_ID = keccak256("USDC/USD");

    address internal owner = makeAddr("owner");
    address internal buyer = makeAddr("buyer");
    address internal paymentRecipient = makeAddr("paymentRecipient");

    MockERC20 internal stratax;
    MockERC20 internal usdc;
    MockPyth internal pyth;
    StrataxTokenSale internal sale;

    function setUp() public {
        stratax = new MockERC20("Stratax Token", "STRATAX", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pyth = new MockPyth();

        StrataxTokenSale saleImpl = new StrataxTokenSale();
        bytes memory initData = abi.encodeWithSelector(
            StrataxTokenSale.initialize.selector,
            owner,
            address(stratax),
            address(pyth),
            paymentRecipient,
            STRATAX_PRICE_USD
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(saleImpl), initData);
        sale = StrataxTokenSale(payable(address(proxy)));

        vm.prank(owner);
        sale.whitelistPaymentToken(address(usdc), USDC_PRICE_ID, 1 hours);

        pyth.setPrice(USDC_PRICE_ID, int64(1e8), -8); // $1.00

        stratax.mint(address(sale), 1_000_000e18);
        usdc.mint(buyer, 10_000e6);

        vm.prank(buyer);
        usdc.approve(address(sale), type(uint256).max);
    }

    function test_QuoteReturnsExpectedStrataxAmount() public view {
        uint256 paymentAmount = 100e6; // 100 USDC
        uint256 quoteAmount = sale.quote(address(usdc), paymentAmount);

        // $100 / $0.20 = 500 STRATAX
        assertEq(quoteAmount, 500e18);
    }

    function test_BuyTransfersPaymentAndStratax() public {
        uint256 paymentAmount = 100e6;
        uint256 minOut = 499e18;

        uint256 buyerStrataxBefore = stratax.balanceOf(buyer);
        uint256 recipientUsdcBefore = usdc.balanceOf(paymentRecipient);

        vm.prank(buyer);
        uint256 out = sale.buy(address(usdc), paymentAmount, minOut, new bytes[](0), address(0));

        uint256 immediateUnlock = (out * sale.PUBLIC_SALE_TGE_BPS()) / sale.BPS();

        assertEq(out, 500e18);
        assertEq(stratax.balanceOf(buyer), buyerStrataxBefore + immediateUnlock);
        assertEq(usdc.balanceOf(paymentRecipient), recipientUsdcBefore + paymentAmount);
    }

    function test_ClaimVestedTokensAfterHalfDuration() public {
        uint256 paymentAmount = 100e6;

        vm.prank(buyer);
        uint256 out = sale.buy(address(usdc), paymentAmount, 499e18, new bytes[](0), address(0));

        uint256 immediateUnlock = (out * sale.PUBLIC_SALE_TGE_BPS()) / sale.BPS();
        uint256 vested = out - immediateUnlock;

        vm.warp(block.timestamp + (sale.PUBLIC_SALE_VESTING_DURATION() / 2));

        uint256 claimable = sale.getClaimableVested(buyer);
        assertApproxEqAbs(claimable, vested / 2, 1, "half-duration vested claim mismatch");

        uint256 buyerBalanceBefore = stratax.balanceOf(buyer);
        vm.prank(buyer);
        uint256 claimed = sale.claimVestedTokens();

        assertEq(claimed, claimable);
        assertEq(stratax.balanceOf(buyer), buyerBalanceBefore + claimed);
    }

    function test_BuyRevertsWhenPaymentTokenNotWhitelisted() public {
        MockERC20 dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        dai.mint(buyer, 1000e18);

        vm.prank(buyer);
        dai.approve(address(sale), type(uint256).max);

        vm.prank(buyer);
        vm.expectRevert("Payment token not whitelisted");
        sale.buy(address(dai), 100e18, 0, new bytes[](0), address(0));
    }

    function test_BuyRevertsWhenPriceIsStale() public {
        vm.warp(block.timestamp + 2 hours);

        vm.prank(buyer);
        vm.expectRevert("stale price");
        sale.buy(address(usdc), 100e6, 0, new bytes[](0), address(0));
    }

    function test_BuyWithPythUpdateDataRequiresFee() public {
        pyth.setUpdateFee(0.01 ether);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"1234";
        vm.deal(buyer, 1 ether);

        vm.prank(buyer);
        vm.expectRevert("Insufficient update fee");
        sale.buy{value: 0.005 ether}(address(usdc), 100e6, 0, updateData, address(0));
    }

    function test_BuyWithPythUpdateDataSucceeds() public {
        pyth.setUpdateFee(0.01 ether);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"abcd";

        vm.deal(buyer, 1 ether);

        uint256 pythBalanceBefore = address(pyth).balance;

        vm.prank(buyer);
        uint256 out = sale.buy{value: 0.02 ether}(address(usdc), 100e6, 499e18, updateData, address(0));

        assertEq(out, 500e18);
        assertEq(address(pyth).balance, pythBalanceBefore + 0.01 ether);
    }

    function test_BuyRevertsWhenSalePaused() public {
        vm.prank(owner);
        sale.pauseSale();

        vm.prank(buyer);
        vm.expectRevert("Sale is paused");
        sale.buy(address(usdc), 100e6, 0, new bytes[](0), address(0));
    }

    function test_BuyRevertsWhenSaleClosed() public {
        vm.prank(owner);
        sale.closeSale();

        vm.prank(buyer);
        vm.expectRevert("Sale is closed");
        sale.buy(address(usdc), 100e6, 0, new bytes[](0), address(0));
    }

    function test_ClaimStillWorksAfterSaleClosed() public {
        vm.prank(buyer);
        sale.buy(address(usdc), 100e6, 499e18, new bytes[](0), address(0));

        vm.prank(owner);
        sale.closeSale();

        vm.warp(block.timestamp + sale.PUBLIC_SALE_VESTING_DURATION());

        uint256 claimable = sale.getClaimableVested(buyer);
        assertTrue(claimable > 0, "claimable should be > 0");

        uint256 buyerBalanceBefore = stratax.balanceOf(buyer);
        vm.prank(buyer);
        sale.claimVestedTokens();

        assertEq(stratax.balanceOf(buyer), buyerBalanceBefore + claimable);
    }

    function test_OwnerCanWithdrawForeignToken() public {
        MockERC20 dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        dai.mint(address(sale), 250e18);

        uint256 ownerBefore = dai.balanceOf(owner);

        vm.prank(owner);
        sale.withdrawProceeds(address(dai), owner, 100e18);

        assertEq(dai.balanceOf(owner), ownerBefore + 100e18);
        assertEq(dai.balanceOf(address(sale)), 150e18);
    }

    function test_WithdrawForeignTokenRevertsForStrataxToken() public {
        vm.prank(owner);
        vm.expectRevert("Cannot withdraw STRATAX");
        sale.withdrawProceeds(address(stratax), owner, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                         REFERRAL SYSTEM
    //////////////////////////////////////////////////////////////*/

    // ── setReferralFeeBps ────────────────────────────────────────

    function test_SetReferralFeeBps_OwnerCanSet() public {
        vm.prank(owner);
        sale.setReferralFeeBps(500);
        assertEq(sale.referralFeeBps(), 500);
    }

    function test_SetReferralFeeBps_EmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit StrataxTokenSale.ReferralFeeUpdated(0, 500);
        sale.setReferralFeeBps(500);
    }

    function test_SetReferralFeeBps_RevertsAboveMax() public {
        uint256 tooHigh = sale.MAX_REFERRAL_FEE_BPS() + 1;
        vm.prank(owner);
        vm.expectRevert("Referral fee exceeds max");
        sale.setReferralFeeBps(tooHigh);
    }

    function test_SetReferralFeeBps_AtMaxSucceeds() public {
        uint256 maxBps = sale.MAX_REFERRAL_FEE_BPS();
        vm.prank(owner);
        sale.setReferralFeeBps(maxBps);
        assertEq(sale.referralFeeBps(), maxBps);
    }

    function test_SetReferralFeeBps_CanBeSetToZero() public {
        vm.prank(owner);
        sale.setReferralFeeBps(500);

        vm.prank(owner);
        sale.setReferralFeeBps(0);
        assertEq(sale.referralFeeBps(), 0);
    }

    function test_SetReferralFeeBps_RevertsForNonOwner() public {
        vm.prank(buyer);
        vm.expectRevert();
        sale.setReferralFeeBps(500);
    }

    // ── buy() referral accounting ────────────────────────────────

    function test_Buy_WithReferrer_AccumulatesEarnings() public {
        address referrer = makeAddr("referrer");
        uint256 feeBps = 500; // 5%

        vm.prank(owner);
        sale.setReferralFeeBps(feeBps);

        vm.prank(buyer);
        uint256 out = sale.buy(address(usdc), 100e6, 0, new bytes[](0), referrer);

        // 100 USDC / $0.20 = 500 STRATAX; 5% = 25 STRATAX referral
        uint256 expectedReferral = (out * feeBps) / sale.BPS();
        assertEq(sale.referralEarnings(referrer), expectedReferral);
    }

    function test_Buy_WithReferrer_ReferralNotTransferredImmediately() public {
        address referrer = makeAddr("referrer");

        vm.prank(owner);
        sale.setReferralFeeBps(500);

        uint256 referrerBalanceBefore = stratax.balanceOf(referrer);

        vm.prank(buyer);
        sale.buy(address(usdc), 100e6, 0, new bytes[](0), referrer);

        // Referral tokens should NOT be transferred yet
        assertEq(stratax.balanceOf(referrer), referrerBalanceBefore);
    }

    function test_Buy_WithReferrer_EmitsReferralRewardedEvent() public {
        address referrer = makeAddr("referrer");

        vm.prank(owner);
        sale.setReferralFeeBps(500);

        vm.prank(buyer);
        vm.expectEmit(true, true, false, false);
        emit StrataxTokenSale.ReferralRewarded(
            referrer,
            buyer,
            0 /* any amount */
        );
        sale.buy(address(usdc), 100e6, 0, new bytes[](0), referrer);
    }

    function test_Buy_WithReferrer_CountedInTotalPublicSaleSold() public {
        address referrer = makeAddr("referrer");
        uint256 feeBps = 500;

        vm.prank(owner);
        sale.setReferralFeeBps(feeBps);

        vm.prank(buyer);
        uint256 out = sale.buy(address(usdc), 100e6, 0, new bytes[](0), referrer);

        uint256 referralAmount = (out * feeBps) / sale.BPS();
        assertEq(sale.totalPublicSaleSold(), out + referralAmount);
    }

    function test_Buy_ReferrerEqualsZeroAddress_NoReferral() public {
        vm.prank(owner);
        sale.setReferralFeeBps(500);

        vm.prank(buyer);
        uint256 out = sale.buy(address(usdc), 100e6, 0, new bytes[](0), address(0));

        assertEq(sale.totalPublicSaleSold(), out, "no referral should be counted");
    }

    function test_Buy_ReferrerEqualsBuyer_NoReferral() public {
        vm.prank(owner);
        sale.setReferralFeeBps(500);

        vm.prank(buyer);
        uint256 out = sale.buy(address(usdc), 100e6, 0, new bytes[](0), buyer);

        assertEq(sale.referralEarnings(buyer), 0, "self-referral must not earn rewards");
        assertEq(sale.totalPublicSaleSold(), out, "only buyer amount counted");
    }

    function test_Buy_ReferralFeeBpsZero_NoReferral() public {
        // referralFeeBps starts at 0
        address referrer = makeAddr("referrer");

        vm.prank(buyer);
        uint256 out = sale.buy(address(usdc), 100e6, 0, new bytes[](0), referrer);

        assertEq(sale.referralEarnings(referrer), 0);
        assertEq(sale.totalPublicSaleSold(), out);
    }

    function test_Buy_MultipleReferralPurchases_EarningsAccumulate() public {
        address referrer = makeAddr("referrer");
        uint256 feeBps = 1_000; // 10%

        vm.prank(owner);
        sale.setReferralFeeBps(feeBps);

        address buyer2 = makeAddr("buyer2");
        usdc.mint(buyer2, 10_000e6);
        vm.prank(buyer2);
        usdc.approve(address(sale), type(uint256).max);

        vm.prank(buyer);
        uint256 out1 = sale.buy(address(usdc), 100e6, 0, new bytes[](0), referrer);

        vm.prank(buyer2);
        uint256 out2 = sale.buy(address(usdc), 200e6, 0, new bytes[](0), referrer);

        uint256 expected = (out1 * feeBps) / sale.BPS() + (out2 * feeBps) / sale.BPS();
        assertEq(sale.referralEarnings(referrer), expected);
    }

    // ── claimReferralRewards ─────────────────────────────────────

    function test_ClaimReferralRewards_TransfersTokensToReferrer() public {
        address referrer = makeAddr("referrer");

        vm.prank(owner);
        sale.setReferralFeeBps(500);

        vm.prank(buyer);
        uint256 out = sale.buy(address(usdc), 100e6, 0, new bytes[](0), referrer);

        uint256 expectedReferral = (out * 500) / sale.BPS();
        uint256 referrerBefore = stratax.balanceOf(referrer);

        vm.prank(referrer);
        uint256 claimed = sale.claimReferralRewards();

        assertEq(claimed, expectedReferral);
        assertEq(stratax.balanceOf(referrer), referrerBefore + expectedReferral);
    }

    function test_ClaimReferralRewards_ZerosOutEarnings() public {
        address referrer = makeAddr("referrer");

        vm.prank(owner);
        sale.setReferralFeeBps(500);

        vm.prank(buyer);
        sale.buy(address(usdc), 100e6, 0, new bytes[](0), referrer);

        vm.prank(referrer);
        sale.claimReferralRewards();

        assertEq(sale.referralEarnings(referrer), 0);
    }

    function test_ClaimReferralRewards_EmitsEvent() public {
        address referrer = makeAddr("referrer");

        vm.prank(owner);
        sale.setReferralFeeBps(500);

        vm.prank(buyer);
        uint256 out = sale.buy(address(usdc), 100e6, 0, new bytes[](0), referrer);

        uint256 expectedReferral = (out * 500) / sale.BPS();

        vm.prank(referrer);
        vm.expectEmit(true, false, false, true);
        emit StrataxTokenSale.ReferralRewardsClaimed(referrer, expectedReferral);
        sale.claimReferralRewards();
    }

    function test_ClaimReferralRewards_RevertsWithNoEarnings() public {
        address referrer = makeAddr("referrer");

        vm.prank(referrer);
        vm.expectRevert("No referral rewards to claim");
        sale.claimReferralRewards();
    }

    function test_ClaimReferralRewards_CanClaimAfterSaleClosed() public {
        address referrer = makeAddr("referrer");

        vm.prank(owner);
        sale.setReferralFeeBps(500);

        vm.prank(buyer);
        sale.buy(address(usdc), 100e6, 0, new bytes[](0), referrer);

        vm.prank(owner);
        sale.closeSale();

        // Claim should still work after sale closes
        vm.prank(referrer);
        uint256 claimed = sale.claimReferralRewards();
        assertTrue(claimed > 0);
    }

    function test_ClaimReferralRewards_CannotDoubleClaimInSameBlock() public {
        address referrer = makeAddr("referrer");

        vm.prank(owner);
        sale.setReferralFeeBps(500);

        vm.prank(buyer);
        sale.buy(address(usdc), 100e6, 0, new bytes[](0), referrer);

        vm.prank(referrer);
        sale.claimReferralRewards();

        vm.prank(referrer);
        vm.expectRevert("No referral rewards to claim");
        sale.claimReferralRewards();
    }

    function test_ClaimReferralRewards_AccumulateAcrossPurchasesThenClaim() public {
        address referrer = makeAddr("referrer");
        uint256 feeBps = 1_000; // 10%

        vm.prank(owner);
        sale.setReferralFeeBps(feeBps);

        address buyer2 = makeAddr("buyer2");
        usdc.mint(buyer2, 10_000e6);
        vm.prank(buyer2);
        usdc.approve(address(sale), type(uint256).max);

        vm.prank(buyer);
        uint256 out1 = sale.buy(address(usdc), 100e6, 0, new bytes[](0), referrer);

        vm.prank(buyer2);
        uint256 out2 = sale.buy(address(usdc), 200e6, 0, new bytes[](0), referrer);

        uint256 totalExpected = (out1 * feeBps) / sale.BPS() + (out2 * feeBps) / sale.BPS();

        uint256 referrerBefore = stratax.balanceOf(referrer);

        vm.prank(referrer);
        uint256 claimed = sale.claimReferralRewards();

        assertEq(claimed, totalExpected);
        assertEq(stratax.balanceOf(referrer), referrerBefore + totalExpected);
        assertEq(sale.referralEarnings(referrer), 0);
    }
}
