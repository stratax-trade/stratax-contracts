// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Stratax_Aave_1Inch as Stratax} from "../../src/core/position-types/Stratax_Aave_1Inch.sol";
import {StrataxPositionNft} from "../../src/core/StrataxPositionNft.sol";
import {StrataxConfigManager} from "../../src/core/StrataxConfigManager.sol";
import {StrataxProtocolBeacon} from "../../src/core/StrataxProtocolBeacon.sol";
import {AaveOneInchPositionAdapter} from "../../src/core/adapters/AaveOneInchPositionAdapter.sol";
import {StrataxOracle} from "../../src/core/StrataxOracle.sol";
import {FeeCollector} from "../../src/core/FeeCollector.sol";
import {StrataxAaveLib} from "../../src/libraries/lending/StrataxAaveLib.sol";
import {Stratax1InchLib} from "../../src/libraries/swapping/Stratax1InchLib.sol";
import {IPool} from "../../src/interfaces/external/IPool.sol";
import {ConstantsEtMainnet} from "../Constants.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Test that records actual swap data used during test execution
/// @dev Run via: node test/scripts/calculate_and_save_swap_data.js
/// @dev This test is meant to be run from the node script to record swap data with real 1inch API
contract RecordSwapData is Test, ConstantsEtMainnet {
    bytes32 internal constant LENDING_AAVE_V3_ID = keccak256("LENDING:AAVE_V3");
    bytes32 internal constant SWAP_ONEINCH_V6_ID = keccak256("SWAP:ONEINCH_V6");

    Stratax public stratax;
    StrataxOracle public strataxOracle;
    FeeCollector public feeCollector;
    StrataxPositionNft public strataxPositionNft;
    StrataxConfigManager public strataxConfigManager;
    address public ownerTrader;
    uint256 public tokenId;

    mapping(bytes32 => bool) private recordedSwapKeys;

    function setUp() public {
        ownerTrader = address(0x123);
        address admin = makeAddr("admin");

        // Match StrataxForkTestBase deployment pattern so generated proxy addresses line up.
        StrataxOracle strataxOracleImplementation = new StrataxOracle();
        bytes memory oracleInitData = abi.encodeWithSelector(StrataxOracle.initialize.selector, admin);
        ERC1967Proxy oracleProxy = new ERC1967Proxy(address(strataxOracleImplementation), oracleInitData);
        strataxOracle = StrataxOracle(address(oracleProxy));

        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = WETH;

        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = USDC_PRICE_FEED;
        priceFeeds[1] = WETH_PRICE_FEED;

        vm.prank(admin);
        strataxOracle.setPriceFeeds(tokens, priceFeeds);

        Stratax strataxImplementation = new Stratax();
        UpgradeableBeacon strataxBeacon = UpgradeableBeacon(
            address(
                new StrataxProtocolBeacon(address(strataxImplementation), admin, LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID)
            )
        );

        FeeCollector feeCollectorImplementation = new FeeCollector();
        bytes memory feeCollectorInitData =
            abi.encodeWithSelector(FeeCollector.initialize.selector, address(0), admin, uint256(5));
        ERC1967Proxy feeCollectorProxy = new ERC1967Proxy(address(feeCollectorImplementation), feeCollectorInitData);
        feeCollector = FeeCollector(address(feeCollectorProxy));

        StrataxPositionNft strataxPositionNftImplementation = new StrataxPositionNft();

        StrataxPositionNft.StrataxPositionNftInitParams memory nftParams =
            StrataxPositionNft.StrataxPositionNftInitParams({
                strataxOracle: address(strataxOracle),
                feeCollector: address(feeCollector),
                configManager: address(this),
                owner: admin,
                uri: "https://api.stratax.io/nft/metadata/"
            });

        bytes memory nftInitData = abi.encodeWithSelector(StrataxPositionNft.initialize.selector, nftParams);
        ERC1967Proxy nftProxy = new ERC1967Proxy(address(strataxPositionNftImplementation), nftInitData);
        strataxPositionNft = StrataxPositionNft(address(nftProxy));

        vm.prank(admin);
        feeCollector.setStrataxPositionNft(address(strataxPositionNft));

        {
            StrataxConfigManager implementation = new StrataxConfigManager();
            bytes memory initData =
                abi.encodeWithSelector(StrataxConfigManager.initialize.selector, admin, address(strataxPositionNft));
            ERC1967Proxy managerProxy = new ERC1967Proxy(address(implementation), initData);
            strataxConfigManager = StrataxConfigManager(address(managerProxy));
        }
        vm.prank(admin);
        strataxPositionNft.setConfigManager(address(strataxConfigManager));

        bytes32 lendingProtocolId = LENDING_AAVE_V3_ID;
        bytes32 swapProtocolId = SWAP_ONEINCH_V6_ID;
        AaveOneInchPositionAdapter adapter = new AaveOneInchPositionAdapter(address(strataxPositionNft));
        vm.prank(admin);
        strataxConfigManager.setProtocolPairConfig(
            lendingProtocolId, swapProtocolId, address(strataxBeacon), address(adapter)
        );

        StrataxAaveLib.InitParams memory lendingConfig = StrataxAaveLib.InitParams({
            pool: AAVE_POOL,
            dataProvider: AAVE_PROTOCOL_DATA_PROVIDER,
            flashLoanFeeBps: IPool(AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL(),
            defaultBorrowSafetyMargin: 9950,
            defaultMaxLeverageOffset: 75
        });
        Stratax1InchLib.Config memory swapConfig = Stratax1InchLib.Config({router: INCH_ROUTER});

        vm.prank(admin);
        strataxConfigManager.setPlatformConfig(
            lendingProtocolId, swapProtocolId, abi.encode(lendingConfig), abi.encode(swapConfig)
        );

        // Mint position NFT which deploys Stratax proxy
        StrataxPositionNft.MintPositionParams memory emptyParams;
        (uint256 _tokenId, address strataxProxy) = strataxPositionNft.mintPositionByProtocolIds(
            ownerTrader, USDC, WETH, lendingProtocolId, swapProtocolId, false, emptyParams
        );
        tokenId = _tokenId;
        stratax = Stratax(strataxProxy);
    }

    /// @notice Get 1inch swap data via FFI
    function get1inchSwapData(address fromToken, address toToken, uint256 amount, address fromAddress)
        internal
        returns (bytes memory swapData, string memory key)
    {
        string[] memory inputs = new string[](6);
        inputs[0] = "node";
        inputs[1] = "test/scripts/get_1inch_swap.js";
        inputs[2] = vm.toString(fromToken);
        inputs[3] = vm.toString(toToken);
        inputs[4] = vm.toString(amount);
        inputs[5] = vm.toString(fromAddress);

        bytes memory result = vm.ffi(inputs);
        string memory jsonResponse = string(result);

        bytes memory dataBytes = vm.parseJson(jsonResponse, ".tx.data");
        swapData = abi.decode(dataBytes, (bytes));

        // Include fromAddress because 1inch calldata is tied to the sender address.
        string memory fromSymbol = fromToken == WETH ? "WETH" : "USDC";
        string memory toSymbol = toToken == WETH ? "WETH" : "USDC";
        key = string.concat(fromSymbol, "_to_", toSymbol, "_", vm.toString(amount), "_from_", vm.toString(fromAddress));

        return (swapData, key);
    }

    function _recordSwapAndGet(address fromToken, address toToken, uint256 amount, address fromAddress)
        internal
        returns (bytes memory)
    {
        (bytes memory swapData, string memory key) = get1inchSwapData(fromToken, toToken, amount, fromAddress);
        bytes32 keyHash = keccak256(bytes(key));

        // Avoid duplicate API calls/entries for identical swap keys.
        if (recordedSwapKeys[keyHash]) {
            return swapData;
        }
        recordedSwapKeys[keyHash] = true;

        console.log("SWAP_START");
        console.log("KEY:", key);
        console.log("FROM_TOKEN:", fromToken);
        console.log("TO_TOKEN:", toToken);
        console.log("FROM_AMOUNT:", amount);
        console.log("SWAP_DATA:", vm.toString(swapData));
        console.log("SWAP_END");

        return swapData;
    }

    function _recordSwap(address fromToken, address toToken, uint256 amount, address fromAddress) internal {
        _recordSwapAndGet(fromToken, toToken, amount, fromAddress);
    }

    /// @notice Record swap data by running actual test with 1inch API
    function test_RecordActualSwapData() public {
        console.log("SWAP_DATA_RECORD_START");
        console.log("BLOCK_NUMBER:", block.number);

        // test_FFI_Get1inchSwapData
        _recordSwap(USDC, WETH, 1000 * 10 ** 6, address(stratax));

        // Open-position swap keys used across StrataxForkTest.
        uint256 collateral1000 = 1000 * 10 ** 6;
        uint256 collateral2000 = 2000 * 10 ** 6;

        (uint256 flashLoan38939, uint256 borrow38939) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: 38_939, collateralAmount: collateral1000, collateralTokenPrice: 0, borrowTokenPrice: 0
            })
        );
        _recordSwap(WETH, USDC, borrow38939, address(stratax));

        (uint256 flashLoan20000, uint256 borrow20000) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: 20_000, collateralAmount: collateral1000, collateralTokenPrice: 0, borrowTokenPrice: 0
            })
        );
        _recordSwap(WETH, USDC, borrow20000, address(stratax));

        (uint256 flashLoan25000_1000, uint256 borrow25000_1000) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: 25_000, collateralAmount: collateral1000, collateralTokenPrice: 0, borrowTokenPrice: 0
            })
        );
        _recordSwap(WETH, USDC, borrow25000_1000, address(stratax));

        (uint256 flashLoan30000, uint256 borrow30000) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: 30_000, collateralAmount: collateral1000, collateralTokenPrice: 0, borrowTokenPrice: 0
            })
        );
        bytes memory openSwap30000 = _recordSwapAndGet(WETH, USDC, borrow30000, address(stratax));

        // Equivalent params used by mint-and-open flows with 2,000 USDC collateral at 2.5x leverage.
        (uint256 flashLoan25000_2000, uint256 borrow25000_2000) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: 25_000, collateralAmount: collateral2000, collateralTokenPrice: 0, borrowTokenPrice: 0
            })
        );
        _recordSwap(WETH, USDC, borrow25000_2000, address(stratax));

        uint256 maxLeverage = stratax.getMaxAchievableLeverageBinary();
        (uint256 flashLoanMax, uint256 borrowMax) = stratax.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: maxLeverage,
                collateralAmount: collateral2000,
                collateralTokenPrice: 0,
                borrowTokenPrice: 0
            })
        );
        _recordSwap(WETH, USDC, borrowMax, address(stratax));

        // Open a reference position to derive unwind amounts used by tests.
        deal(USDC, ownerTrader, collateral1000);
        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax), collateral1000);
        stratax.createLeveragedPosition(flashLoan30000, collateral1000, borrow30000, openSwap30000, 0);

        // test_PartialUnwindPosition -> calculateUnwindParams(partialDebt), then *102/100
        (, uint256 totalDebt30000,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax));
        uint256 halfDebt30000 = totalDebt30000 / 2;
        (uint256 partialUnwindCollateral30000,,) = stratax.calculateUnwindParams(halfDebt30000);
        uint256 partialUnwindCollateral30000Buffered = (partialUnwindCollateral30000 * 102) / 100;
        _recordSwap(USDC, WETH, partialUnwindCollateral30000Buffered, address(stratax));

        vm.stopPrank();

        // Re-mint a fresh USDC/WETH position for 20k leverage unwind variants.
        StrataxPositionNft.MintPositionParams memory emptyParams1;
        (uint256 tokenId20k, address strataxProxy20k) = strataxPositionNft.mintPositionByProtocolIds(
            ownerTrader, USDC, WETH, LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID, false, emptyParams1
        );
        Stratax stratax20k = Stratax(strataxProxy20k);

        deal(USDC, ownerTrader, collateral1000);
        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax20k), collateral1000);
        bytes memory openSwap20000Proxy = _recordSwapAndGet(WETH, USDC, borrow20000, address(stratax20k));
        stratax20k.createLeveragedPosition(flashLoan20000, collateral1000, borrow20000, openSwap20000Proxy, 0);

        // test_OpenAndUnwindPosition + test_UnwindFullPositionAndBurnNFT (full unwind with manual 3% buffer)
        (uint256 fullUnwindCollateral20k,,) = stratax20k.calculateUnwindParams(type(uint256).max);
        uint256 fullUnwindCollateral20kBuffered = (fullUnwindCollateral20k * 103) / 100;
        _recordSwap(USDC, WETH, fullUnwindCollateral20kBuffered, address(stratax20k));

        // test_CalculateUnwindParamsWithSlippageBps_FullUnwind
        (uint256 fullUnwindWithBps20k,,) = stratax20k.calculateUnwindParams(type(uint256).max, 300);
        _recordSwap(USDC, WETH, fullUnwindWithBps20k, address(stratax20k));

        vm.stopPrank();

        // Fresh USDC/WETH position for 25k leverage unwind-with-slippage variant.
        StrataxPositionNft.MintPositionParams memory emptyParams2;
        (, address strataxProxy25k) = strataxPositionNft.mintPositionByProtocolIds(
            ownerTrader, USDC, WETH, LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID, false, emptyParams2
        );
        Stratax stratax25k = Stratax(strataxProxy25k);

        deal(USDC, ownerTrader, collateral1000);
        vm.startPrank(ownerTrader);
        IERC20(USDC).approve(address(stratax25k), collateral1000);
        bytes memory openSwap25000Proxy = _recordSwapAndGet(WETH, USDC, borrow25000_1000, address(stratax25k));
        stratax25k.createLeveragedPosition(flashLoan25000_1000, collateral1000, borrow25000_1000, openSwap25000Proxy, 0);

        (, uint256 totalDebt25000,,,,) = IPool(AAVE_POOL).getUserAccountData(address(stratax25k));
        uint256 halfDebt25000 = totalDebt25000 / 2;
        (uint256 partialUnwindWithBps25k,,) = stratax25k.calculateUnwindParams(halfDebt25000, 300);
        _recordSwap(USDC, WETH, partialUnwindWithBps25k, address(stratax25k));
        vm.stopPrank();

        // test_MultiplePositionsSameOwner second position (WETH collateral / USDC borrow)
        address multiTrader = address(0xBEEF);
        StrataxPositionNft.MintPositionParams memory emptyParams3;
        (, address strataxProxy2) = strataxPositionNft.mintPositionByProtocolIds(
            multiTrader, WETH, USDC, LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID, false, emptyParams3
        );
        Stratax stratax2 = Stratax(strataxProxy2);

        (, uint256 borrowReversePair) = stratax2.calculateOpenParams(
            Stratax.CalcOpenParams({
                desiredLeverage: 20_000, collateralAmount: 0.5 ether, collateralTokenPrice: 0, borrowTokenPrice: 0
            })
        );
        _recordSwap(USDC, WETH, borrowReversePair, address(strataxProxy2));

        // Silence warnings for calculated values used only for deterministic scenario coverage.
        flashLoan38939;
        flashLoan25000_2000;
        flashLoanMax;
        tokenId20k;

        console.log("SWAP_DATA_RECORD_END");
    }
}
