// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract FeeCollectorUnitTest is Test {
    FeeCollector internal feeCollector;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    address internal mockNft;
    address internal position1;
    address internal position2;
    address internal staking;

    address internal constant ASSET_A = address(0xA11CE);
    address internal constant ASSET_B = address(0xB0B);

    function setUp() public {
        mockNft = makeAddr("mockNft");
        position1 = makeAddr("position1");
        position2 = makeAddr("position2");
        staking = makeAddr("staking");

        feeCollector = new FeeCollector();
        feeCollector.initialize(mockNft, address(this), 50);
        feeCollector.setStakingContract(staking);
        feeCollector.setStakerRewardsBps(3_000);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        vm.mockCall(mockNft, abi.encodeWithSignature("strataxAddressToTokenId(address)", position1), abi.encode(1));
        vm.mockCall(mockNft, abi.encodeWithSignature("strataxAddressToTokenId(address)", position2), abi.encode(2));

        usdc.mint(position1, 1_000e6);
        usdc.mint(position2, 1_000e6);
        weth.mint(position1, 10e18);

        vm.prank(position1);
        usdc.approve(address(feeCollector), type(uint256).max);
        vm.prank(position2);
        usdc.approve(address(feeCollector), type(uint256).max);
        vm.prank(position1);
        weth.approve(address(feeCollector), type(uint256).max);
    }

    function test_CollectStakerRewards_DistributesPerTokenAndIsIdempotent() public {
        vm.prank(position1);
        feeCollector.collectFeesAndRecordVolume(address(usdc), 100e6, ASSET_A, 1_000e18);

        vm.prank(position2);
        feeCollector.collectFeesAndRecordVolume(address(usdc), 50e6, ASSET_B, 500e18);

        uint256 ownerBefore = usdc.balanceOf(address(this));

        vm.prank(staking);
        feeCollector.collectStakerRewardsForAllAssets();

        assertEq(usdc.balanceOf(staking), 45e6, "staking share mismatch");
        assertEq(usdc.balanceOf(address(this)) - ownerBefore, 105e6, "owner share mismatch");

        assertEq(feeCollector.feeTokenStakerFeesPaid(address(usdc)), 45e6, "USDC staker paid mismatch");
        assertEq(feeCollector.feeTokenOwnerFeesPaid(address(usdc)), 105e6, "USDC owner paid mismatch");

        uint256 stakingAfterFirst = usdc.balanceOf(staking);
        uint256 ownerAfterFirst = usdc.balanceOf(address(this));

        vm.prank(staking);
        feeCollector.collectStakerRewardsForAllAssets();

        assertEq(usdc.balanceOf(staking), stakingAfterFirst, "second collect should not pay stakers again");
        assertEq(usdc.balanceOf(address(this)), ownerAfterFirst, "second collect should not pay owner again");
    }

    function test_CollectStakerRewards_UsesAccountingNotRawBalance() public {
        vm.prank(position1);
        feeCollector.collectFeesAndRecordVolume(address(usdc), 100e6, ASSET_A, 1_000e18);

        vm.prank(staking);
        feeCollector.collectStakerRewardsForAllAssets();

        // Donate extra tokens directly; they should not be distributed by accounting-based collector.
        usdc.mint(address(feeCollector), 77e6);

        uint256 stakingBefore = usdc.balanceOf(staking);
        uint256 ownerBefore = usdc.balanceOf(address(this));

        vm.prank(staking);
        feeCollector.collectStakerRewardsForAllAssets();

        assertEq(usdc.balanceOf(staking), stakingBefore, "donated balance should not inflate staker payout");
        assertEq(usdc.balanceOf(address(this)), ownerBefore, "donated balance should not inflate owner payout");
        assertEq(usdc.balanceOf(address(feeCollector)), 77e6, "donated balance should remain in contract");
    }

    function test_CollectFees_AllowsDifferentFeeTokensForSameAsset() public {
        vm.prank(position1);
        feeCollector.collectFeesAndRecordVolume(address(usdc), 5e6, ASSET_A, 100e18);

        vm.prank(position1);
        feeCollector.collectFeesAndRecordVolume(address(weth), 1e18, ASSET_A, 100e18);

        assertEq(feeCollector.feeTokenFeesCollected(address(usdc)), 5e6, "USDC collected mismatch");
        assertEq(feeCollector.feeTokenFeesCollected(address(weth)), 1e18, "WETH collected mismatch");
    }

    function test_CollectStakerRewards_OnlyStakingContract() public {
        vm.prank(position1);
        feeCollector.collectFeesAndRecordVolume(address(usdc), 10e6, ASSET_A, 100e18);

        vm.expectRevert("Only staking contract");
        feeCollector.collectStakerRewardsForAllAssets();
    }

    function test_CollectStakerRewards_MultipleRoundsPayOnlyNewEntitlement() public {
        vm.prank(position1);
        feeCollector.collectFeesAndRecordVolume(address(usdc), 100e6, ASSET_A, 1_000e18);

        vm.prank(staking);
        feeCollector.collectStakerRewardsForAllAssets();

        assertEq(usdc.balanceOf(staking), 30e6, "round1 staker mismatch");
        assertEq(feeCollector.feeTokenStakerFeesPaid(address(usdc)), 30e6, "round1 staker paid mismatch");
        assertEq(feeCollector.feeTokenOwnerFeesPaid(address(usdc)), 70e6, "round1 owner paid mismatch");

        vm.prank(position1);
        feeCollector.collectFeesAndRecordVolume(address(usdc), 40e6, ASSET_A, 400e18);

        vm.prank(staking);
        feeCollector.collectStakerRewardsForAllAssets();

        // Total collected is 140, so staker entitlement is 42 and owner entitlement is 98.
        assertEq(usdc.balanceOf(staking), 42e6, "round2 cumulative staker mismatch");
        assertEq(feeCollector.feeTokenStakerFeesPaid(address(usdc)), 42e6, "round2 staker paid mismatch");
        assertEq(feeCollector.feeTokenOwnerFeesPaid(address(usdc)), 98e6, "round2 owner paid mismatch");
    }
}
