// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Stratax_Aave_Uniswap as StrataxUniswap} from "../../src/core/position-types/Stratax_Aave_Uniswap.sol";
import {StrataxProtocolBeacon} from "../../src/core/StrataxProtocolBeacon.sol";
import {AaveUniswapPositionAdapter} from "../../src/core/adapters/AaveUniswapPositionAdapter.sol";
import {StrataxAavePositionInitConstants} from "../../src/libraries/constants/StrataxAavePositionInitConstants.sol";
import {StrataxUniswapConstants} from "../../src/libraries/constants/StrataxUniswapConstants.sol";
import {StrataxUniswapLib} from "../../src/libraries/swapping/StrataxUniswapLib.sol";
import {IPool} from "../../src/interfaces/external/IPool.sol";
import {StrataxForkTestBase} from "./Base.t.sol";

contract StrataxUniswapForkTest is StrataxForkTestBase {
    bytes32 internal constant SWAP_UNISWAP_V3_ID = keccak256("SWAP:UNISWAP_V3");

    function test_MintAaveUniswapPosition() public {
        AaveUniswapPositionAdapter adapter = _configureDefaultAaveUniswap();
        adapter;

        address positionOwner = address(0xBEEF);
        (uint256 mintedTokenId, address strataxProxy) = strataxPositionNft.mintPositionByProtocolIds(
            positionOwner, USDC, WETH, LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID, false, bytes("")
        );

        assertTrue(strataxProxy != address(0), "Stratax proxy should be deployed");
        assertEq(strataxPositionNft.ownerOf(mintedTokenId), positionOwner, "NFT owner should match mint recipient");
        _assertMintedUniswapPosition(mintedTokenId, strataxProxy);
    }

    function test_MintAndOpenUniswapPositionInOneCall() public {
        AaveUniswapPositionAdapter adapter = _configureDefaultAaveUniswap();

        address positionOwner = address(0xCAFE);
        uint256 collateralAmount = 2000 * 10 ** 6; // 2000 USDC
        uint256 desiredLeverage = 25_000; // 2.5x
        uint24 poolFee = StrataxUniswapConstants.ETHEREUM_DEFAULT_UNISWAP_POOL_FEE;

        (bytes memory mintCallData,) = adapter.buildCreateLeveragedPositionCallData(
            positionOwner,
            USDC,
            WETH,
            LENDING_AAVE_V3_ID,
            SWAP_UNISWAP_V3_ID,
            collateralAmount,
            desiredLeverage,
            poolFee,
            0
        );

        deal(USDC, positionOwner, collateralAmount);

        vm.startPrank(positionOwner);
        IERC20(USDC).approve(address(strataxPositionNft), collateralAmount);

        (bool mintSuccess, bytes memory mintResult) = address(strataxPositionNft).call(mintCallData);
        if (!mintSuccess) {
            assembly {
                revert(add(mintResult, 0x20), mload(mintResult))
            }
        }

        (uint256 mintedTokenId, address strataxProxy) = abi.decode(mintResult, (uint256, address));
        vm.stopPrank();

        assertEq(strataxPositionNft.ownerOf(mintedTokenId), positionOwner, "NFT owner should match mint recipient");
        _assertMintedUniswapPosition(mintedTokenId, strataxProxy);

        (uint256 totalCollateral, uint256 totalDebt,,,, uint256 healthFactor) =
            IPool(AAVE_POOL).getUserAccountData(strataxProxy);

        assertTrue(totalCollateral > 0, "Position should have collateral after open");
        assertTrue(totalDebt > 0, "Position should have debt after open");
        assertTrue(healthFactor > 1e18, "Health factor should be above 1");
    }

    function _configureDefaultAaveUniswap() internal returns (AaveUniswapPositionAdapter adapter) {
        // Deploy dedicated implementation + beacon for the Aave+Uniswap protocol pair.
        StrataxUniswap uniswapImplementation = new StrataxUniswap();
        StrataxProtocolBeacon uniswapBeacon =
            new StrataxProtocolBeacon(address(uniswapImplementation), admin, LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID);

        vm.startPrank(admin);
        adapter = new AaveUniswapPositionAdapter(address(strataxPositionNft));
        strataxConfigManager.setProtocolPairConfig(
            LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID, address(uniswapBeacon), address(adapter)
        );

        bytes memory lendingData = abi.encode(
            StrataxAavePositionInitConstants.ethereumConfigParams(IPool(AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL())
        );
        bytes memory swapData = abi.encode(StrataxUniswapConstants.ethereumConfigParams());
        strataxConfigManager.setPlatformConfig(LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID, lendingData, swapData);
        vm.stopPrank();
    }

    function _assertMintedUniswapPosition(uint256 mintedTokenId, address strataxProxy) internal view {
        assertTrue(strataxProxy != address(0), "Stratax proxy should be deployed");

        (
            address collateralToken,
            address borrowToken,
            address positionProxy,
            bytes32 strategyId,
            bytes32 swapProtocolId,
            bytes32 lendingProtocolId,
            bool isActive,
            bool isBurned,
            uint256 createdAt
        ) = strataxPositionNft.positions(mintedTokenId);

        strategyId;
        createdAt;

        assertEq(collateralToken, USDC, "Collateral token should be USDC");
        assertEq(borrowToken, WETH, "Borrow token should be WETH");
        assertEq(positionProxy, strataxProxy, "Stored position proxy should match mint return value");
        assertEq(swapProtocolId, SWAP_UNISWAP_V3_ID, "Swap protocol id should be Uniswap V3");
        assertEq(lendingProtocolId, LENDING_AAVE_V3_ID, "Lending protocol id should be Aave V3");
        assertTrue(isActive, "Position should be active");
        assertTrue(!isBurned, "Position should not be burned");

        StrataxUniswap position = StrataxUniswap(strataxProxy);
        assertEq(address(position.uniswapRouter()), StrataxUniswapConstants.ETHEREUM_UNISWAP_V3_ROUTER);

        StrataxUniswapLib.Config memory swapConfig =
            abi.decode(strataxPositionNft.swapConfigByProtocolId(SWAP_UNISWAP_V3_ID), (StrataxUniswapLib.Config));
        assertEq(swapConfig.router, StrataxUniswapConstants.ETHEREUM_UNISWAP_V3_ROUTER);
        assertEq(swapConfig.quoter, StrataxUniswapConstants.ETHEREUM_UNISWAP_V3_QUOTER_V2);
        assertEq(swapConfig.poolFee, StrataxUniswapConstants.ETHEREUM_DEFAULT_UNISWAP_POOL_FEE);
    }
}
