// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StrataxConfigManager} from "../../src/core/StrataxConfigManager.sol";
import {IStrataxPositionAdapter} from "../../src/interfaces/internal/IStrataxPositionAdapter.sol";
import {IStrataxProtocolBeacon} from "../../src/interfaces/internal/IStrataxProtocolBeacon.sol";

// ─── Minimal mocks ───────────────────────────────────────────────────────────

/// @dev Records every call made to it so we can assert the config manager
///      delegates correctly to the NFT contract.
contract MockPositionNft {
    struct PairConfigCall {
        bytes32 lendingId;
        bytes32 swapId;
        address beacon;
        address adapter;
    }

    PairConfigCall[] public pairConfigCalls;
    mapping(bytes32 => mapping(bytes32 => address)) public pairAdapters;
    mapping(bytes32 => bytes) public lendingConfigs;
    mapping(bytes32 => bytes) public swapConfigs;
    mapping(bytes32 => uint256) public flashLoanFees;

    function setProtocolPairConfig(bytes32 lendingId, bytes32 swapId, address beacon, address adapter) external {
        pairConfigCalls.push(PairConfigCall(lendingId, swapId, beacon, adapter));
    }

    function setPairAdapter(bytes32 lendingId, bytes32 swapId, address adapter) external {
        pairAdapters[lendingId][swapId] = adapter;
    }

    function setLendingProtocolConfig(bytes32 lendingId, bytes calldata data) external {
        lendingConfigs[lendingId] = data;
    }

    function setSwapProtocolConfig(bytes32 swapId, bytes calldata data) external {
        swapConfigs[swapId] = data;
    }

    function getPairConfigCall(uint256 index) external view returns (PairConfigCall memory) {
        return pairConfigCalls[index];
    }

    function updateProtocolFlashLoanFee(bytes32 lendingId, uint256 feeBps) external {
        flashLoanFees[lendingId] = feeBps;
    }
}

contract MockAdapter {
    bytes32 public immutable lendingId;
    bytes32 public immutable swapId;

    constructor(bytes32 lendingId_, bytes32 swapId_) {
        lendingId = lendingId_;
        swapId = swapId_;
    }

    function supportsProtocolPair(bytes32 l, bytes32 s) external view returns (bool) {
        return l == lendingId && s == swapId;
    }
}

contract MockBeacon {
    bytes32 public immutable lendingId;
    bytes32 public immutable swapId;

    constructor(bytes32 lendingId_, bytes32 swapId_) {
        lendingId = lendingId_;
        swapId = swapId_;
    }

    function supportsProtocolPair(bytes32 l, bytes32 s) external view returns (bool) {
        return l == lendingId && s == swapId;
    }
}

// ─── Test suite ──────────────────────────────────────────────────────────────

contract StrataxConfigManagerTest is Test {
    bytes32 internal constant LENDING_ID = keccak256("AAVE_V3");
    bytes32 internal constant SWAP_ID = keccak256("UNISWAP_V3");
    bytes32 internal constant OTHER_LENDING_ID = keccak256("FLUID_V1");
    bytes32 internal constant OTHER_SWAP_ID = keccak256("ONEINCH_V6");

    bytes internal constant LENDING_DATA = hex"aabb";
    bytes internal constant SWAP_DATA = hex"ccdd";

    address internal owner = makeAddr("owner");
    address internal nonOwner = makeAddr("nonOwner");

    MockPositionNft internal nft;
    MockAdapter internal adapter;
    MockBeacon internal beacon;
    StrataxConfigManager internal cfg;

    function setUp() public {
        nft = new MockPositionNft();
        adapter = new MockAdapter(LENDING_ID, SWAP_ID);
        beacon = new MockBeacon(LENDING_ID, SWAP_ID);

        StrataxConfigManager impl = new StrataxConfigManager();
        bytes memory initData = abi.encodeWithSelector(StrataxConfigManager.initialize.selector, owner, address(nft));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        cfg = StrataxConfigManager(address(proxy));
    }

    // ── initialize ───────────────────────────────────────────────────────────

    function test_Initialize_SetsOwnerAndNft() public view {
        assertEq(cfg.owner(), owner);
        assertEq(address(cfg.positionNft()), address(nft));
    }

    function test_Initialize_RevertsWithZeroNft() public {
        StrataxConfigManager impl = new StrataxConfigManager();
        bytes memory initData = abi.encodeWithSelector(StrataxConfigManager.initialize.selector, owner, address(0));
        vm.expectRevert("Invalid position NFT");
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_CannotBeCalledTwice() public {
        vm.prank(owner);
        vm.expectRevert();
        cfg.initialize(owner, address(nft));
    }

    // ── registerProtocolPair ─────────────────────────────────────────────────

    function test_RegisterProtocolPair_CallsDelegatesCorrectly() public {
        vm.prank(owner);
        cfg.registerProtocolPair(LENDING_ID, SWAP_ID, address(beacon), address(adapter), LENDING_DATA, SWAP_DATA);

        // setProtocolPairConfig delegated
        MockPositionNft.PairConfigCall memory call = nft.getPairConfigCall(0);
        assertEq(call.lendingId, LENDING_ID);
        assertEq(call.swapId, SWAP_ID);
        assertEq(call.beacon, address(beacon));
        assertEq(call.adapter, address(adapter));

        // setPairAdapter delegated
        assertEq(nft.pairAdapters(LENDING_ID, SWAP_ID), address(adapter));

        // platform configs delegated
        assertEq(nft.lendingConfigs(LENDING_ID), LENDING_DATA);
        assertEq(nft.swapConfigs(SWAP_ID), SWAP_DATA);
    }

    function test_RegisterProtocolPair_RevertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        cfg.registerProtocolPair(LENDING_ID, SWAP_ID, address(beacon), address(adapter), LENDING_DATA, SWAP_DATA);
    }

    function test_RegisterProtocolPair_RevertsWithZeroLendingId() public {
        vm.prank(owner);
        vm.expectRevert("Invalid lending protocol id");
        cfg.registerProtocolPair(bytes32(0), SWAP_ID, address(beacon), address(adapter), LENDING_DATA, SWAP_DATA);
    }

    function test_RegisterProtocolPair_RevertsWithZeroSwapId() public {
        vm.prank(owner);
        vm.expectRevert("Invalid swap protocol id");
        cfg.registerProtocolPair(LENDING_ID, bytes32(0), address(beacon), address(adapter), LENDING_DATA, SWAP_DATA);
    }

    function test_RegisterProtocolPair_RevertsWithZeroBeacon() public {
        vm.prank(owner);
        vm.expectRevert("Invalid beacon");
        cfg.registerProtocolPair(LENDING_ID, SWAP_ID, address(0), address(adapter), LENDING_DATA, SWAP_DATA);
    }

    function test_RegisterProtocolPair_RevertsWithZeroAdapter() public {
        vm.prank(owner);
        vm.expectRevert("Invalid adapter");
        cfg.registerProtocolPair(LENDING_ID, SWAP_ID, address(beacon), address(0), LENDING_DATA, SWAP_DATA);
    }

    function test_RegisterProtocolPair_RevertsWithEOABeacon() public {
        address eoa = makeAddr("eoa");
        vm.prank(owner);
        vm.expectRevert("Beacon must be contract");
        cfg.registerProtocolPair(LENDING_ID, SWAP_ID, eoa, address(adapter), LENDING_DATA, SWAP_DATA);
    }

    function test_RegisterProtocolPair_RevertsWithEOAAdapter() public {
        address eoa = makeAddr("eoa");
        vm.prank(owner);
        vm.expectRevert("Adapter must be contract");
        cfg.registerProtocolPair(LENDING_ID, SWAP_ID, address(beacon), eoa, LENDING_DATA, SWAP_DATA);
    }

    function test_RegisterProtocolPair_RevertsWhenAdapterProtocolIdMismatch() public {
        MockAdapter wrongAdapter = new MockAdapter(OTHER_LENDING_ID, SWAP_ID);
        vm.prank(owner);
        vm.expectRevert("Adapter protocol ids mismatch");
        cfg.registerProtocolPair(LENDING_ID, SWAP_ID, address(beacon), address(wrongAdapter), LENDING_DATA, SWAP_DATA);
    }

    function test_RegisterProtocolPair_RevertsWhenBeaconProtocolIdMismatch() public {
        MockBeacon wrongBeacon = new MockBeacon(OTHER_LENDING_ID, SWAP_ID);
        vm.prank(owner);
        vm.expectRevert("Beacon protocol ids mismatch");
        cfg.registerProtocolPair(LENDING_ID, SWAP_ID, address(wrongBeacon), address(adapter), LENDING_DATA, SWAP_DATA);
    }

    function test_RegisterProtocolPair_RevertsWithEmptyLendingData() public {
        vm.prank(owner);
        vm.expectRevert("Missing lending config");
        cfg.registerProtocolPair(LENDING_ID, SWAP_ID, address(beacon), address(adapter), "", SWAP_DATA);
    }

    function test_RegisterProtocolPair_RevertsWithEmptySwapData() public {
        vm.prank(owner);
        vm.expectRevert("Missing swap config");
        cfg.registerProtocolPair(LENDING_ID, SWAP_ID, address(beacon), address(adapter), LENDING_DATA, "");
    }

    // ── setProtocolPairConfig ────────────────────────────────────────────────

    function test_SetProtocolPairConfig_DelegatesWithoutPlatformConfigs() public {
        vm.prank(owner);
        cfg.setProtocolPairConfig(LENDING_ID, SWAP_ID, address(beacon), address(adapter));

        assertEq(nft.getPairConfigCall(0).beacon, address(beacon));
        assertEq(nft.pairAdapters(LENDING_ID, SWAP_ID), address(adapter));
        // lending/swap configs must remain untouched
        assertEq(nft.lendingConfigs(LENDING_ID).length, 0);
        assertEq(nft.swapConfigs(SWAP_ID).length, 0);
    }

    function test_SetProtocolPairConfig_RevertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        cfg.setProtocolPairConfig(LENDING_ID, SWAP_ID, address(beacon), address(adapter));
    }

    function test_SetProtocolPairConfig_RevertsWithZeroIds() public {
        vm.prank(owner);
        vm.expectRevert("Invalid lending protocol id");
        cfg.setProtocolPairConfig(bytes32(0), SWAP_ID, address(beacon), address(adapter));
    }

    // ── setPlatformConfig ────────────────────────────────────────────────────

    function test_SetPlatformConfig_UpdatesBothConfigs() public {
        bytes memory newLending = hex"1122";
        bytes memory newSwap = hex"3344";

        vm.prank(owner);
        cfg.setPlatformConfig(LENDING_ID, SWAP_ID, newLending, newSwap);

        assertEq(nft.lendingConfigs(LENDING_ID), newLending);
        assertEq(nft.swapConfigs(SWAP_ID), newSwap);
    }

    function test_SetPlatformConfig_RevertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        cfg.setPlatformConfig(LENDING_ID, SWAP_ID, LENDING_DATA, SWAP_DATA);
    }

    function test_SetPlatformConfig_RevertsWithZeroLendingId() public {
        vm.prank(owner);
        vm.expectRevert("Invalid lending protocol id");
        cfg.setPlatformConfig(bytes32(0), SWAP_ID, LENDING_DATA, SWAP_DATA);
    }

    function test_SetPlatformConfig_RevertsWithZeroSwapId() public {
        vm.prank(owner);
        vm.expectRevert("Invalid swap protocol id");
        cfg.setPlatformConfig(LENDING_ID, bytes32(0), LENDING_DATA, SWAP_DATA);
    }

    function test_SetPlatformConfig_RevertsWithEmptyLendingData() public {
        vm.prank(owner);
        vm.expectRevert("Missing lending config");
        cfg.setPlatformConfig(LENDING_ID, SWAP_ID, "", SWAP_DATA);
    }

    function test_SetPlatformConfig_RevertsWithEmptySwapData() public {
        vm.prank(owner);
        vm.expectRevert("Missing swap config");
        cfg.setPlatformConfig(LENDING_ID, SWAP_ID, LENDING_DATA, "");
    }

    // ── setPairAdapter ───────────────────────────────────────────────────────

    function test_SetPairAdapter_UpdatesAdapterOnNft() public {
        MockAdapter newAdapter = new MockAdapter(LENDING_ID, SWAP_ID);

        vm.prank(owner);
        cfg.setPairAdapter(LENDING_ID, SWAP_ID, address(newAdapter));

        assertEq(nft.pairAdapters(LENDING_ID, SWAP_ID), address(newAdapter));
    }

    function test_SetPairAdapter_RevertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        cfg.setPairAdapter(LENDING_ID, SWAP_ID, address(adapter));
    }

    // ── updatePlatformFlashLoanFee ───────────────────────────────────────────

    function test_UpdateFlashLoanFee_StoresOnNft() public {
        uint256 newFee = 9;
        vm.prank(owner);
        cfg.updatePlatformFlashLoanFee(LENDING_ID, newFee);

        assertEq(nft.flashLoanFees(LENDING_ID), newFee);
    }

    function test_UpdateFlashLoanFee_RevertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        cfg.updatePlatformFlashLoanFee(LENDING_ID, 9);
    }

    function test_UpdateFlashLoanFee_RevertsWhenAtOrAboveMaxPrecision() public {
        // Fetch the constant from the lib via a helper call
        // We rely on the require: newFeeBps < FLASHLOAN_FEE_PREC
        // The test verifies the upper-bound guard fires — exact value comes from StrataxCalculations.
        // We use a safely-large value that must exceed any reasonable precision constant.
        vm.prank(owner);
        vm.expectRevert("Invalid flash loan fee");
        cfg.updatePlatformFlashLoanFee(LENDING_ID, type(uint256).max);
    }

    // ── upgrade / UUPS ───────────────────────────────────────────────────────

    function test_Upgrade_RevertsForNonOwner() public {
        StrataxConfigManager newImpl = new StrataxConfigManager();
        vm.prank(nonOwner);
        vm.expectRevert();
        cfg.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_OwnerCanUpgrade() public {
        StrataxConfigManager newImpl = new StrataxConfigManager();
        vm.prank(owner);
        cfg.upgradeToAndCall(address(newImpl), "");
        // State must be preserved after upgrade
        assertEq(cfg.owner(), owner);
        assertEq(address(cfg.positionNft()), address(nft));
    }
}
