// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {StrataxStaking} from "../../src/core/StrataxStaking.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract FeeCollectorStakingIntegrationTest is Test {
    FeeCollector internal feeCollector;
    StrataxStaking internal staking;

    MockERC20 internal stratax;
    MockERC20 internal rewardA;
    MockERC20 internal rewardB;

    address internal mockNft;
    address internal position1;
    address internal position2;
    address internal alice;
    address internal bob;

    address internal constant ASSET_A = address(0xAAA1);
    address internal constant ASSET_B = address(0xBBB2);

    function setUp() public {
        mockNft = makeAddr("mockNft");
        position1 = makeAddr("position1");
        position2 = makeAddr("position2");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        stratax = new MockERC20("Stratax", "STRATAX", 18);
        rewardA = new MockERC20("Reward A", "RWA", 18);
        rewardB = new MockERC20("Reward B", "RWB", 18);

        feeCollector = new FeeCollector();
        feeCollector.initialize(mockNft, address(this), 50);
        feeCollector.setStakerRewardsBps(2_500);

        staking = new StrataxStaking(address(this), IERC20(address(stratax)), address(feeCollector));
        feeCollector.setStakingContract(address(staking));

        vm.mockCall(mockNft, abi.encodeWithSignature("strataxAddressToTokenId(address)", position1), abi.encode(1));
        vm.mockCall(mockNft, abi.encodeWithSignature("strataxAddressToTokenId(address)", position2), abi.encode(2));

        stratax.mint(alice, 1_000e18);
        stratax.mint(bob, 1_000e18);

        rewardA.mint(position1, 1_000e18);
        rewardA.mint(position2, 1_000e18);
        rewardB.mint(position1, 1_000e18);

        vm.prank(alice);
        stratax.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        stratax.approve(address(staking), type(uint256).max);

        vm.prank(position1);
        rewardA.approve(address(feeCollector), type(uint256).max);
        vm.prank(position2);
        rewardA.approve(address(feeCollector), type(uint256).max);
        vm.prank(position1);
        rewardB.approve(address(feeCollector), type(uint256).max);
    }

    function test_SyncProtocolRewards_RealFeeCollector_DistributesToStakersAndOwner() public {
        vm.prank(alice);
        staking.deposit(100e18, alice);
        vm.prank(bob);
        staking.deposit(100e18, bob);

        vm.prank(position1);
        feeCollector.collectFeesAndRecordVolume(address(rewardA), 100e18, ASSET_A, 1_000e18);

        vm.prank(position2);
        feeCollector.collectFeesAndRecordVolume(address(rewardA), 60e18, ASSET_B, 500e18);

        uint256 ownerBefore = rewardA.balanceOf(address(this));

        staking.syncProtocolRewards();

        // Staker share is 25% of 160 = 40, split equally across Alice and Bob.
        assertEq(staking.pendingReward(alice, address(rewardA)), 20e18, "alice pending mismatch");
        assertEq(staking.pendingReward(bob, address(rewardA)), 20e18, "bob pending mismatch");

        // Owner should have received the remaining 120 directly from FeeCollector.
        assertEq(rewardA.balanceOf(address(this)) - ownerBefore, 120e18, "owner payout mismatch");

        assertEq(feeCollector.feeTokenStakerFeesPaid(address(rewardA)), 40e18, "rewardA staker paid mismatch");
        assertEq(feeCollector.feeTokenOwnerFeesPaid(address(rewardA)), 120e18, "rewardA owner paid mismatch");

        vm.prank(alice);
        staking.claimAllRewards();
        vm.prank(bob);
        staking.claimAllRewards();

        assertEq(rewardA.balanceOf(alice), 20e18, "alice claim mismatch");
        assertEq(rewardA.balanceOf(bob), 20e18, "bob claim mismatch");
    }

    function test_SyncProtocolRewards_MultiTokenFlow_WithUndistributedThenClaim() public {
        // Create protocol fees before any stakers exist.
        vm.prank(position1);
        feeCollector.collectFeesAndRecordVolume(address(rewardA), 80e18, ASSET_A, 1_000e18);

        vm.prank(position1);
        feeCollector.collectFeesAndRecordVolume(address(rewardB), 40e18, ASSET_B, 500e18);

        staking.syncProtocolRewards();

        // Staker share (25%) goes to undistributed while supply is zero.
        assertEq(staking.undistributedRewards(address(rewardA)), 20e18, "rewardA undistributed mismatch");
        assertEq(staking.undistributedRewards(address(rewardB)), 10e18, "rewardB undistributed mismatch");

        vm.prank(alice);
        staking.deposit(100e18, alice);

        vm.prank(alice);
        staking.claimAllRewards();

        assertEq(rewardA.balanceOf(alice), 20e18, "alice rewardA mismatch");
        assertEq(rewardB.balanceOf(alice), 10e18, "alice rewardB mismatch");
    }
}
