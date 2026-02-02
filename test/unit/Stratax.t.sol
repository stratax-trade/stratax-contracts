// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Stratax} from "../../src/Stratax.sol";
import {StrataxPositionNft} from "../../src/StrataxPositionNft.sol";
import {StrataxOracle} from "../../src/StrataxOracle.sol";
import {ConstantsEtMainnet} from "../Constants.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract StrataxUnitTest is Test, ConstantsEtMainnet {
    Stratax public stratax;
    Stratax public strataxImplementation;
    UpgradeableBeacon public strataxBeacon;
    StrataxPositionNft public strataxPositionNft;
    StrataxPositionNft public strataxPositionNftImplementation;
    TransparentUpgradeableProxy public nftProxy;
    ProxyAdmin public proxyAdmin;
    StrataxOracle public strataxOracle;
    address public ownerTrader;
    uint256 public tokenId;

    function setUp() public {
        ownerTrader = address(0x123);

        // Mock price feed contracts to return 8 decimals
        vm.mockCall(USDC_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(WETH_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));

        // Mock Aave pool flash loan fee
        vm.mockCall(AAVE_POOL, abi.encodeWithSignature("FLASHLOAN_PREMIUM_TOTAL()"), abi.encode(uint128(9)));

        // Mock token decimals
        vm.mockCall(USDC, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.mockCall(WETH, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));

        strataxOracle = new StrataxOracle();
        strataxOracle.setPriceFeed(USDC, USDC_PRICE_FEED);
        strataxOracle.setPriceFeed(WETH, WETH_PRICE_FEED);

        // Deploy Stratax implementation and beacon
        strataxImplementation = new Stratax();
        strataxBeacon = new UpgradeableBeacon(address(strataxImplementation), address(this));

        // Deploy StrataxPositionNft implementation
        strataxPositionNftImplementation = new StrataxPositionNft();

        // Deploy ProxyAdmin
        proxyAdmin = new ProxyAdmin(address(this));

        // Initialize StrataxPositionNft via TransparentUpgradeableProxy
        StrataxPositionNft.StrataxPositionNftInitParams memory nftParams = StrataxPositionNft
            .StrataxPositionNftInitParams({
            strataxBeacon: address(strataxBeacon),
            aavePool: AAVE_POOL,
            aaveDataProvider: AAVE_PROTOCOL_DATA_PROVIDER,
            oneInchRouter: INCH_ROUTER,
            strataxOracle: address(strataxOracle),
            feeCollector: address(0),
            owner: address(this),
            uri: "https://stratax.io/nft/"
        });

        bytes memory nftInitData = abi.encodeWithSelector(StrataxPositionNft.initialize.selector, nftParams);
        nftProxy =
            new TransparentUpgradeableProxy(address(strataxPositionNftImplementation), address(proxyAdmin), nftInitData);
        strataxPositionNft = StrataxPositionNft(address(nftProxy));

        // Mint position NFT which deploys Stratax proxy
        (uint256 _tokenId, address strataxProxy) = strataxPositionNft.mintPositionNft(ownerTrader, USDC, WETH);
        tokenId = _tokenId;
        stratax = Stratax(strataxProxy);
    }

    function test_ContractDeployment() public view {
        assertEq(address(stratax.aavePool()), AAVE_POOL, "AAVE Pool address mismatch");
        assertEq(address(stratax.oneInchRouter()), INCH_ROUTER, "1inch Router address mismatch");
        assertEq(stratax.collateralToken(), USDC, "Collateral token address mismatch");
        assertEq(stratax.borrowToken(), WETH, "Borrow token address mismatch");
        // Owner is verified via NFT ownership
        assertEq(strataxPositionNft.ownerOf(tokenId), ownerTrader, "NFT owner should be ownerTrader");
    }

    function test_ConstantsAreSet() public pure {
        assertTrue(AAVE_POOL != address(0), "AAVE Pool address is zero");
        assertTrue(USDC != address(0), "USDC address is zero");
        assertTrue(INCH_ROUTER != address(0), "1inch Router address is zero");
    }

    function test_BasisPointsConstant() public view {
        assertEq(stratax.FLASHLOAN_FEE_PREC(), 10000, "FLASHLOAN_FEE_PREC should be 10000");
    }

    function test_OwnerCanSetFlashLoanFee() public {
        vm.prank(ownerTrader);
        stratax.setFlashLoanFee(9);
        assertEq(stratax.flashLoanFeeBps(), 9, "Flash loan fee not set correctly");
    }

    function test_BeaconProxySetup() public view {
        assertEq(
            strataxBeacon.implementation(), address(strataxImplementation), "Beacon should point to implementation"
        );
        // Verify stratax is deployed as a proxy
        assertTrue(address(stratax) != address(0), "Stratax proxy should be deployed");
    }

    function test_StrataxProxyInitialized() public view {
        // Verify the Stratax proxy was properly initialized by mintPositionNft
        assertEq(stratax.collateralToken(), USDC, "Collateral token should match");
        assertEq(stratax.borrowToken(), WETH, "Borrow token should match");
        assertEq(stratax.tokenId(), tokenId, "Token ID should match");
    }
}
