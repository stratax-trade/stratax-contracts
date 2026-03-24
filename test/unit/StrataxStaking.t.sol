// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StrataxStaking} from "../../src/core/StrataxStaking.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeCollector} from "../mocks/MockFeeCollector.sol";

contract StrataxStakingUnitTest is Test {
    MockERC20 internal stratax;
    MockERC20 internal rewardA;
    MockERC20 internal rewardB;
    MockFeeCollector internal feeCollector;
    StrataxStaking internal staking;

    address internal alice;
    address internal bob;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        stratax = new MockERC20("Stratax", "STRATAX", 18);
        rewardA = new MockERC20("Reward A", "RWA", 18);
        rewardB = new MockERC20("Reward B", "RWB", 18);

        feeCollector = new MockFeeCollector();
        staking = new StrataxStaking(address(this), IERC20(address(stratax)), address(feeCollector));

        stratax.mint(alice, 1_000e18);
        stratax.mint(bob, 1_000e18);
        stratax.mint(address(this), 2_000e18);

        vm.prank(alice);
        stratax.approve(address(staking), type(uint256).max);

        vm.prank(bob);
        stratax.approve(address(staking), type(uint256).max);

        stratax.approve(address(staking), type(uint256).max);
    }

    function test_DepositAndRedeem() public {
        vm.prank(alice);
        uint256 shares = staking.deposit(100e18, alice);
        assertEq(shares, 100e18, "shares mismatch");
        assertEq(staking.balanceOf(alice), 100e18, "share balance mismatch");
        assertEq(staking.totalAssets(), 100e18, "total assets mismatch");

        vm.prank(alice);
        uint256 assetsOut = staking.redeem(40e18, alice, alice);
        assertEq(assetsOut, 40e18, "redeem assets mismatch");
        assertEq(staking.balanceOf(alice), 60e18, "remaining shares mismatch");
    }

    function test_EmissionYieldAccruesToStakers() public {
        staking.fundStrataxEmissions(100e18);
        staking.setStrataxEmissionRatePerSecond(1e18); // 1 STRATAX/sec

        vm.prank(alice);
        staking.deposit(100e18, alice);

        vm.warp(block.timestamp + 10);

        // Any state-changing call accrues emission.
        vm.prank(alice);
        staking.claimAllRewards();

        assertEq(staking.totalAssets(), 110e18, "assets should include emitted yield");

        vm.prank(alice);
        uint256 assetsOut = staking.redeem(100e18, alice, alice);
        assertApproxEqAbs(assetsOut, 110e18, 1, "staker should receive principal + emitted yield");
    }

    function test_SyncAndClaimMultiTokenRewards() public {
        vm.prank(alice);
        staking.deposit(100e18, alice);

        vm.prank(bob);
        staking.deposit(100e18, bob);

        feeCollector.addTrackedToken(address(rewardA));
        feeCollector.addTrackedToken(address(rewardB));

        rewardA.mint(address(feeCollector), 50e18);
        rewardB.mint(address(feeCollector), 80e18);

        feeCollector.setPendingReward(address(rewardA), 50e18);
        feeCollector.setPendingReward(address(rewardB), 80e18);

        staking.syncProtocolRewards();

        assertEq(staking.pendingReward(alice, address(rewardA)), 25e18, "alice rewardA pending mismatch");
        assertEq(staking.pendingReward(alice, address(rewardB)), 40e18, "alice rewardB pending mismatch");
        assertEq(staking.pendingReward(bob, address(rewardA)), 25e18, "bob rewardA pending mismatch");
        assertEq(staking.pendingReward(bob, address(rewardB)), 40e18, "bob rewardB pending mismatch");

        vm.prank(alice);
        staking.claimAllRewards();

        vm.prank(bob);
        staking.claimAllRewards();

        assertEq(rewardA.balanceOf(alice), 25e18, "alice rewardA claim mismatch");
        assertEq(rewardB.balanceOf(alice), 40e18, "alice rewardB claim mismatch");
        assertEq(rewardA.balanceOf(bob), 25e18, "bob rewardA claim mismatch");
        assertEq(rewardB.balanceOf(bob), 40e18, "bob rewardB claim mismatch");
    }

    function test_UndistributedRewardsWhenNoStakers() public {
        feeCollector.addTrackedToken(address(rewardA));
        rewardA.mint(address(feeCollector), 10e18);
        feeCollector.setPendingReward(address(rewardA), 10e18);

        // No stakers yet => rewards should be held as undistributed.
        staking.syncProtocolRewards();
        assertEq(staking.undistributedRewards(address(rewardA)), 10e18, "undistributed mismatch");

        vm.prank(alice);
        staking.deposit(100e18, alice);

        // Trigger distribution from undistributed bucket.
        vm.prank(alice);
        staking.claimAllRewards();

        assertEq(rewardA.balanceOf(alice), 10e18, "alice should receive all previously undistributed rewards");
        assertEq(staking.undistributedRewards(address(rewardA)), 0, "undistributed should be empty");
    }

    function test_TransferSharesAfterSync_OriginalKeepsAccruedRewards() public {
        vm.prank(alice);
        staking.deposit(100e18, alice);

        feeCollector.addTrackedToken(address(rewardA));
        rewardA.mint(address(feeCollector), 30e18);
        feeCollector.setPendingReward(address(rewardA), 30e18);

        // Rewards are pulled and accrued while Alice is sole staker.
        staking.syncProtocolRewards();
        assertEq(staking.pendingReward(alice, address(rewardA)), 30e18, "alice pending should be full reward");

        // Alice transfers all shares after rewards already accrued.
        vm.prank(alice);
        assertTrue(staking.transfer(bob, 100e18), "share transfer failed");

        // Previously accrued rewards should remain claimable by Alice, not Bob.
        assertEq(staking.pendingReward(alice, address(rewardA)), 30e18, "alice should keep pre-transfer rewards");
        assertEq(staking.pendingReward(bob, address(rewardA)), 0, "bob should not inherit past rewards");

        vm.prank(alice);
        staking.claimAllRewards();

        assertEq(rewardA.balanceOf(alice), 30e18, "alice reward claim mismatch");
        assertEq(rewardA.balanceOf(bob), 0, "bob should have no reward from past epoch");
    }

    function test_TransferSharesThenNewRewards_SplitsByCurrentOwnership() public {
        vm.prank(alice);
        staking.deposit(100e18, alice);

        feeCollector.addTrackedToken(address(rewardA));

        // First epoch: Alice gets all, then transfers half shares to Bob.
        rewardA.mint(address(feeCollector), 20e18);
        feeCollector.setPendingReward(address(rewardA), 20e18);
        staking.syncProtocolRewards();

        vm.prank(alice);
        assertTrue(staking.transfer(bob, 50e18), "share transfer failed");

        // Second epoch: split by current balances (50/50).
        rewardA.mint(address(feeCollector), 20e18);
        feeCollector.setPendingReward(address(rewardA), 20e18);
        staking.syncProtocolRewards();

        // Alice: first 20 + half of second 20 = 30
        // Bob: half of second 20 = 10
        assertEq(staking.pendingReward(alice, address(rewardA)), 30e18, "alice combined pending mismatch");
        assertEq(staking.pendingReward(bob, address(rewardA)), 10e18, "bob pending mismatch");

        vm.prank(alice);
        staking.claimAllRewards();
        vm.prank(bob);
        staking.claimAllRewards();

        assertEq(rewardA.balanceOf(alice), 30e18, "alice final reward mismatch");
        assertEq(rewardA.balanceOf(bob), 10e18, "bob final reward mismatch");
    }

    function test_AdminFunctionsRevertForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.setFeeCollector(makeAddr("newFeeCollector"));

        vm.prank(alice);
        vm.expectRevert();
        staking.setStrataxEmissionRatePerSecond(1e18);

        vm.prank(alice);
        vm.expectRevert();
        staking.fundStrataxEmissions(1e18);
    }

    function test_EmissionDoesNotAccrueWithoutStakers() public {
        staking.fundStrataxEmissions(100e18);
        staking.setStrataxEmissionRatePerSecond(1e18);

        vm.warp(block.timestamp + 50);

        // First state update happens while no stakers exist; reserve should stay intact.
        vm.prank(alice);
        staking.deposit(10e18, alice);

        assertEq(
            staking.strataxEmissionRemaining(), 100e18, "emission reserve should not be consumed before first staker"
        );

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        staking.claimAllRewards();

        assertEq(staking.strataxEmissionRemaining(), 90e18, "emission reserve should be consumed once staker exists");
        assertEq(staking.totalAssets(), 20e18, "assets should include emitted yield after staking starts");
    }

    function test_ClaimReward_ClaimsSingleTokenOnly() public {
        vm.prank(alice);
        staking.deposit(100e18, alice);

        feeCollector.addTrackedToken(address(rewardA));
        feeCollector.addTrackedToken(address(rewardB));

        rewardA.mint(address(feeCollector), 40e18);
        rewardB.mint(address(feeCollector), 60e18);
        feeCollector.setPendingReward(address(rewardA), 40e18);
        feeCollector.setPendingReward(address(rewardB), 60e18);

        staking.syncProtocolRewards();

        vm.prank(alice);
        staking.claimReward(address(rewardA));

        assertEq(rewardA.balanceOf(alice), 40e18, "rewardA claim mismatch");
        assertEq(rewardB.balanceOf(alice), 0, "rewardB should remain unclaimed");
        assertEq(staking.pendingReward(alice, address(rewardB)), 60e18, "rewardB pending mismatch");
    }

    function test_SyncWithoutNewRewards_IsNoOpForPendingBalances() public {
        vm.prank(alice);
        staking.deposit(100e18, alice);

        feeCollector.addTrackedToken(address(rewardA));
        rewardA.mint(address(feeCollector), 15e18);
        feeCollector.setPendingReward(address(rewardA), 15e18);

        staking.syncProtocolRewards();
        uint256 pendingBefore = staking.pendingReward(alice, address(rewardA));

        // No additional pending rewards are configured in mock collector.
        staking.syncProtocolRewards();

        uint256 pendingAfter = staking.pendingReward(alice, address(rewardA));
        assertEq(pendingBefore, 15e18, "initial pending mismatch");
        assertEq(pendingAfter, pendingBefore, "pending should not change on empty sync");
    }

    function test_UndistributedRewardsAccumulateAcrossMultipleSyncs() public {
        feeCollector.addTrackedToken(address(rewardA));

        rewardA.mint(address(feeCollector), 10e18);
        feeCollector.setPendingReward(address(rewardA), 10e18);
        staking.syncProtocolRewards();

        rewardA.mint(address(feeCollector), 15e18);
        feeCollector.setPendingReward(address(rewardA), 15e18);
        staking.syncProtocolRewards();

        assertEq(
            staking.undistributedRewards(address(rewardA)), 25e18, "undistributed should accumulate while no stakers"
        );

        vm.prank(alice);
        staking.deposit(100e18, alice);

        vm.prank(alice);
        staking.claimAllRewards();

        assertEq(rewardA.balanceOf(alice), 25e18, "alice should receive full accumulated undistributed rewards");
        assertEq(
            staking.undistributedRewards(address(rewardA)), 0, "undistributed should be cleared after distribution"
        );
    }

    function test_FirstMintOnly_Is1To1Bootstrap() public {
        vm.prank(alice);
        uint256 firstShares = staking.deposit(100e18, alice);
        assertEq(firstShares, 100e18, "first mint should be 1:1");
        assertTrue(staking.initialMintCompleted(), "initial mint flag should be set");

        // Simulate donated assets increasing vault assets without minting shares.
        stratax.mint(address(staking), 100e18);

        vm.prank(bob);
        uint256 secondShares = staking.deposit(100e18, bob);
        assertLt(secondShares, 100e18, "subsequent mint should use ERC4626 pricing, not forced 1:1");
    }

    function test_Gas_SyncProtocolRewards_OneTokenVsTwentyTokens() public {
        address gasUserOne = makeAddr("gasUserOne");
        address gasUserTwenty = makeAddr("gasUserTwenty");

        // Scenario A: 1 tracked fee token.
        MockFeeCollector feeCollectorOne = new MockFeeCollector();
        StrataxStaking stakingOne =
            new StrataxStaking(address(this), IERC20(address(stratax)), address(feeCollectorOne));

        stratax.mint(gasUserOne, 100e18);
        vm.prank(gasUserOne);
        stratax.approve(address(stakingOne), type(uint256).max);
        vm.prank(gasUserOne);
        stakingOne.deposit(100e18, gasUserOne);

        MockERC20 rewardSingle = new MockERC20("Gas Reward Single", "GRS", 18);
        feeCollectorOne.addTrackedToken(address(rewardSingle));
        rewardSingle.mint(address(feeCollectorOne), 1e18);
        feeCollectorOne.setPendingReward(address(rewardSingle), 1e18);

        uint256 gasStartOne = gasleft();
        stakingOne.syncProtocolRewards();
        uint256 gasUsedOne = gasStartOne - gasleft();

        // Scenario B: 20 tracked fee tokens.
        MockFeeCollector feeCollectorTwenty = new MockFeeCollector();
        StrataxStaking stakingTwenty =
            new StrataxStaking(address(this), IERC20(address(stratax)), address(feeCollectorTwenty));

        stratax.mint(gasUserTwenty, 100e18);
        vm.prank(gasUserTwenty);
        stratax.approve(address(stakingTwenty), type(uint256).max);
        vm.prank(gasUserTwenty);
        stakingTwenty.deposit(100e18, gasUserTwenty);

        for (uint256 i = 0; i < 20; i++) {
            MockERC20 rewardToken = new MockERC20("Gas Reward", "GR", 18);
            feeCollectorTwenty.addTrackedToken(address(rewardToken));
            rewardToken.mint(address(feeCollectorTwenty), 1e18);
            feeCollectorTwenty.setPendingReward(address(rewardToken), 1e18);
        }

        uint256 gasStartTwenty = gasleft();
        stakingTwenty.syncProtocolRewards();
        uint256 gasUsedTwenty = gasStartTwenty - gasleft();

        emit log_named_uint("Gas used syncProtocolRewards (1 token)", gasUsedOne);
        emit log_named_uint("Gas used syncProtocolRewards (20 tokens)", gasUsedTwenty);
        emit log_named_uint("Gas delta (20 - 1)", gasUsedTwenty - gasUsedOne);

        /* GAS COSTS
        Gas used syncProtocolRewards (1 token): 123289
        Gas used syncProtocolRewards (20 tokens): 1983209
        Gas delta (20 - 1): 1859920
        */

        assertGt(gasUsedTwenty, gasUsedOne, "Expected 20-token sync to cost more gas than 1-token sync");
    }
}
