// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {StrataxPositionNft} from "./StrataxPositionNft.sol";
import {Stratax_Aave_1Inch} from "./position-types/Stratax_Aave_1Inch.sol";
import {Stratax_Aave_Uniswap} from "./position-types/Stratax_Aave_Uniswap.sol";
import {Stratax_Fluid_Uniswap} from "./position-types/Stratax_Fluid_Uniswap.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStrataxPositionAdapter} from "../interfaces/internal/IStrataxPositionAdapter.sol";

/// @title StrataxRouter
/// @notice Simplifies interaction with the Stratax protocol by handling minting, position opening,
///         and management in clean single-call functions.
/// @dev The Router mints NFTs to itself, opens positions (as the temporary owner), then transfers
///      the NFT to the user — all atomically within one transaction.
///      For 1inch positions, swap data must be generated off-chain before calling the router.
contract StrataxRouter is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant LENDING_AAVE_V3_ID = keccak256("LENDING:AAVE_V3");
    bytes32 public constant LENDING_FLUID_V1_ID = keccak256("LENDING:FLUID_V1");
    bytes32 public constant SWAP_ONEINCH_V6_ID = keccak256("SWAP:ONEINCH_V6");
    bytes32 public constant SWAP_UNISWAP_V3_ID = keccak256("SWAP:UNISWAP_V3");

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    StrataxPositionNft public immutable positionNft;

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidPositionNft();
    error NotPositionOwner();
    error PositionNotActive();
    error InvalidSwapProtocol();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _positionNft) {
        if (_positionNft == address(0)) revert InvalidPositionNft();
        positionNft = StrataxPositionNft(_positionNft);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                    POSITION CREATION — MINT ONLY
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints a new position NFT without opening a leveraged position.
    function mintPosition(
        address collateralToken,
        address borrowToken,
        bytes32 lendingProtocolId,
        bytes32 swapProtocolId
    ) external returns (uint256 tokenId, address strataxProxy) {
        return positionNft.mintPosition(msg.sender, collateralToken, borrowToken, lendingProtocolId, swapProtocolId);
    }

    /*//////////////////////////////////////////////////////////////
              POSITION CREATION — UNISWAP (FULLY ON-CHAIN)
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints a new position NFT and opens an Aave+Uniswap leveraged position in one call.
    ///         All parameters are calculated on-chain — no off-chain data required.
    function createAaveUniswapPosition(
        address collateralToken,
        address borrowToken,
        uint256 collateralAmount,
        uint256 desiredLeverage,
        address[] calldata swapPath,
        uint24[] calldata swapFees,
        uint256 minAmountOut
    ) external nonReentrant returns (uint256 tokenId, address strataxProxy) {
        // Mint NFT to router (making router the temporary owner)
        (tokenId, strataxProxy) = positionNft.mintPosition(
            address(this), collateralToken, borrowToken, LENDING_AAVE_V3_ID, SWAP_UNISWAP_V3_ID
        );

        // Transfer collateral from user, approve the proxy
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        IERC20(collateralToken).forceApprove(strataxProxy, collateralAmount);

        // Open position (router is owner via NFT)
        Stratax_Aave_Uniswap(strataxProxy)
            .createLeveragedPosition(desiredLeverage, collateralAmount, swapPath, swapFees, minAmountOut);

        // Transfer NFT to user
        positionNft.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    /// @notice Mints a new position NFT and opens a Fluid+Uniswap leveraged position in one call.
    function createFluidUniswapPosition(
        address collateralToken,
        address borrowToken,
        uint256 collateralAmount,
        uint256 desiredLeverage,
        uint24 poolFee,
        uint256 minAmountOut
    ) external nonReentrant returns (uint256 tokenId, address strataxProxy) {
        (tokenId, strataxProxy) = positionNft.mintPosition(
            address(this), collateralToken, borrowToken, LENDING_FLUID_V1_ID, SWAP_UNISWAP_V3_ID
        );

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        IERC20(collateralToken).forceApprove(strataxProxy, collateralAmount);

        Stratax_Fluid_Uniswap(strataxProxy)
            .createLeveragedPosition(desiredLeverage, collateralAmount, poolFee, minAmountOut);

        positionNft.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
              POSITION CREATION — 1INCH (OFF-CHAIN SWAP DATA)
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints a new position NFT and opens an Aave+1inch leveraged position.
    /// @dev The caller must first:
    ///      1. Call `calculate1InchOpenParams()` to get flashLoanAmount and borrowAmount
    ///      2. Call `predictNextProxyAddress()` to get the predicted proxy address
    ///      3. Call the 1inch API with the predicted proxy as `fromAddress`
    ///      4. Call this function with all computed values
    function createAaveOneInchPosition(
        address collateralToken,
        address borrowToken,
        uint256 collateralAmount,
        uint256 flashLoanAmount,
        uint256 borrowAmount,
        bytes calldata oneInchSwapData,
        uint256 minAmountOut
    ) external nonReentrant returns (uint256 tokenId, address strataxProxy) {
        (tokenId, strataxProxy) = positionNft.mintPosition(
            address(this), collateralToken, borrowToken, LENDING_AAVE_V3_ID, SWAP_ONEINCH_V6_ID
        );

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        IERC20(collateralToken).forceApprove(strataxProxy, collateralAmount);

        Stratax_Aave_1Inch(strataxProxy)
            .createLeveragedPosition(flashLoanAmount, collateralAmount, borrowAmount, oneInchSwapData, minAmountOut);

        positionNft.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
             POSITION MANAGEMENT — UNWIND
    //////////////////////////////////////////////////////////////*/

    /// @notice Unwinds an Aave+Uniswap position. Calculates params on-chain.
    /// @param tokenId The position NFT token ID
    /// @param debtToRepay Amount of debt to repay (use type(uint256).max for full unwind)
    /// @param swapPath Ordered token array for the Uniswap V3 swap path
    /// @param swapFees Uniswap V3 fee tiers for each hop (length == swapPath.length - 1)
    /// @param minReturnAmount Minimum swap output (slippage protection)
    function unwindAaveUniswapPosition(
        uint256 tokenId,
        uint256 debtToRepay,
        address[] calldata swapPath,
        uint24[] calldata swapFees,
        uint256 minReturnAmount
    ) external nonReentrant {
        _validateAndTakeNft(tokenId, SWAP_UNISWAP_V3_ID);

        address proxy = positionNft.getStrataxProxy(tokenId);
        Stratax_Aave_Uniswap position = Stratax_Aave_Uniswap(proxy);
        (uint256 collateralToWithdraw, uint256 debtAmount,) = position.calculateUnwindParams(debtToRepay);
        position.unwindPosition(collateralToWithdraw, debtAmount, swapPath, swapFees, minReturnAmount);

        _returnNft(tokenId);
    }

    /// @notice Unwinds an Aave+1inch position with pre-computed swap data.
    /// @dev Caller must first call `calculateUnwindParams()` on the proxy, then get 1inch swap data.
    function unwindAaveOneInchPosition(
        uint256 tokenId,
        uint256 collateralToWithdraw,
        uint256 debtAmount,
        bytes calldata oneInchSwapData,
        uint256 minReturnAmount
    ) external nonReentrant {
        _validateAndTakeNft(tokenId, SWAP_ONEINCH_V6_ID);

        address proxy = positionNft.getStrataxProxy(tokenId);
        Stratax_Aave_1Inch(proxy).unwindPosition(collateralToWithdraw, debtAmount, oneInchSwapData, minReturnAmount);

        _returnNft(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
             POSITION MANAGEMENT — COLLATERAL & DEBT
    //////////////////////////////////////////////////////////////*/

    /// @notice Supplies additional collateral to a position.
    function supplyCollateral(uint256 tokenId, uint256 amount) external nonReentrant {
        (bytes32 swapProtocolId, address proxy, address collateralToken) = _validateTakeNftAndGetInfo(tokenId);

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(collateralToken).forceApprove(proxy, amount);

        if (swapProtocolId == SWAP_UNISWAP_V3_ID) {
            // Both Aave+Uniswap and Fluid+Uniswap share the same supplyCollateral interface
            Stratax_Aave_Uniswap(proxy).supplyCollateral(amount);
        } else {
            Stratax_Aave_1Inch(proxy).supplyCollateral(amount);
        }

        _returnNft(tokenId);
    }

    /// @notice Withdraws collateral from a position.
    function withdrawCollateral(uint256 tokenId, uint256 amount) external nonReentrant {
        (bytes32 swapProtocolId, address proxy, address collateralToken) = _validateTakeNftAndGetInfo(tokenId);

        if (swapProtocolId == SWAP_UNISWAP_V3_ID) {
            Stratax_Aave_Uniswap(proxy).withdrawCollateral(amount);
        } else {
            Stratax_Aave_1Inch(proxy).withdrawCollateral(amount);
        }

        uint256 routerBalance = IERC20(collateralToken).balanceOf(address(this));
        if (routerBalance > 0) {
            IERC20(collateralToken).safeTransfer(msg.sender, routerBalance);
        }

        _returnNft(tokenId);
    }

    /// @notice Borrows additional debt tokens from a position.
    function borrowDebtToken(uint256 tokenId, uint256 amount) external nonReentrant {
        (bytes32 swapProtocolId, address proxy, address borrowToken) = _validateTakeNftAndGetDebtInfo(tokenId);

        if (swapProtocolId == SWAP_UNISWAP_V3_ID) {
            Stratax_Aave_Uniswap(proxy).borrowDebtToken(amount);
        } else {
            Stratax_Aave_1Inch(proxy).borrowDebtToken(amount);
        }

        uint256 routerBalance = IERC20(borrowToken).balanceOf(address(this));
        if (routerBalance > 0) {
            IERC20(borrowToken).safeTransfer(msg.sender, routerBalance);
        }

        _returnNft(tokenId);
    }

    /// @notice Repays debt on a position.
    function repayDebtToken(uint256 tokenId, uint256 amount) external nonReentrant {
        (bytes32 swapProtocolId, address proxy, address borrowToken) = _validateTakeNftAndGetDebtInfo(tokenId);

        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(borrowToken).forceApprove(proxy, amount);

        if (swapProtocolId == SWAP_UNISWAP_V3_ID) {
            Stratax_Aave_Uniswap(proxy).repayDebtToken(amount);
        } else {
            Stratax_Aave_1Inch(proxy).repayDebtToken(amount);
        }

        uint256 routerBalance = IERC20(borrowToken).balanceOf(address(this));
        if (routerBalance > 0) {
            IERC20(borrowToken).safeTransfer(msg.sender, routerBalance);
        }

        _returnNft(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                         VIEW / HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates open parameters for a 1inch position.
    /// @dev Use the returned flashLoanAmount and borrowAmount when calling the 1inch API.
    function calculate1InchOpenParams(address proxy, uint256 desiredLeverage, uint256 collateralAmount)
        external
        view
        returns (uint256 flashLoanAmount, uint256 borrowAmount)
    {
        Stratax_Aave_1Inch position = Stratax_Aave_1Inch(proxy);
        Stratax_Aave_1Inch.CalcOpenParams memory params = Stratax_Aave_1Inch.CalcOpenParams({
            desiredLeverage: desiredLeverage,
            collateralAmount: collateralAmount,
            collateralTokenPrice: 0,
            borrowTokenPrice: 0
        });
        return position.calculateOpenParams(params);
    }

    /// @notice Predicts the proxy address for the next position minted through this router.
    /// @dev Use this as `fromAddress` when fetching 1inch swap data off-chain.
    function predictNextProxyAddress(
        address collateralToken,
        address borrowToken,
        bytes32 lendingProtocolId,
        bytes32 swapProtocolId
    ) external view returns (address predictedProxy) {
        (address beacon,) = positionNft.protocolPairConfig(lendingProtocolId, swapProtocolId);
        address adapter = positionNft.pairAdapterByProtocolIds(lendingProtocolId, swapProtocolId);
        bytes memory lendingConfigData = positionNft.lendingConfigByProtocolId(lendingProtocolId);
        bytes memory swapConfigData = positionNft.swapConfigByProtocolId(swapProtocolId);

        uint256 nextTokenId = positionNft.getTotalPositionsCreated() + 1;

        bytes memory strataxInitConfig = abi.encode(
            beacon,
            address(positionNft),
            nextTokenId,
            positionNft.strataxOracle(),
            positionNft.feeCollector(),
            collateralToken,
            borrowToken
        );

        bytes32 deploymentSalt = positionNft.getEffectiveCallerCreate2Salt(address(this));

        predictedProxy = IStrataxPositionAdapter(adapter)
            .predictDeploymentAddress(lendingConfigData, swapConfigData, strataxInitConfig, deploymentSalt);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _validateAndTakeNft(uint256 tokenId, bytes32 expectedSwapProtocolId) internal {
        address nftOwner = positionNft.ownerOf(tokenId);
        if (nftOwner != msg.sender) revert NotPositionOwner();

        (,,,, bytes32 swapProtocolId,, bool isActive,,) = positionNft.positions(tokenId);
        if (!isActive) revert PositionNotActive();
        if (swapProtocolId != expectedSwapProtocolId) revert InvalidSwapProtocol();

        positionNft.safeTransferFrom(msg.sender, address(this), tokenId);
    }

    function _validateTakeNftAndGetInfo(uint256 tokenId)
        internal
        returns (bytes32 swapProtocolId, address proxy, address collateralToken)
    {
        address nftOwner = positionNft.ownerOf(tokenId);
        if (nftOwner != msg.sender) revert NotPositionOwner();

        (address _collateralToken,, address _proxy,, bytes32 _swapProtocolId,, bool isActive,,) =
            positionNft.positions(tokenId);
        if (!isActive) revert PositionNotActive();

        positionNft.safeTransferFrom(msg.sender, address(this), tokenId);

        return (_swapProtocolId, _proxy, _collateralToken);
    }

    function _validateTakeNftAndGetDebtInfo(uint256 tokenId)
        internal
        returns (bytes32 swapProtocolId, address proxy, address borrowToken)
    {
        address nftOwner = positionNft.ownerOf(tokenId);
        if (nftOwner != msg.sender) revert NotPositionOwner();

        (, address _borrowToken, address _proxy,, bytes32 _swapProtocolId,, bool isActive,,) =
            positionNft.positions(tokenId);
        if (!isActive) revert PositionNotActive();

        positionNft.safeTransferFrom(msg.sender, address(this), tokenId);

        return (_swapProtocolId, _proxy, _borrowToken);
    }

    function _returnNft(uint256 tokenId) internal {
        positionNft.safeTransferFrom(address(this), msg.sender, tokenId);
    }
}
