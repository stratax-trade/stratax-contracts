// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ISwapExecutor} from "../interfaces/internal/ISwapExecutor.sol";
import {IUniswapV3SwapRouter} from "../../interfaces/external/IUniswapV3SwapRouter.sol";
import {StrataxUniswapLib} from "../../libraries/swapping/StrataxUniswapLib.sol";

/**
 * @title BaseUniswapPosition
 * @notice Swap-only base for Uniswap V3-backed positions.
 */
abstract contract BaseUniswapPosition {
    address public swapRouter;
    ISwapExecutor public swapExecutor;

    uint256[48] private __swapGap;

    function _initUniswapSwap(address _swapRouter, ISwapExecutor _swapExecutor) internal {
        require(_swapRouter != address(0), "Invalid swap router");
        require(address(_swapExecutor) != address(0), "Invalid swap executor");
        swapRouter = _swapRouter;
        swapExecutor = _swapExecutor;
    }

    function uniswapRouter() public view returns (IUniswapV3SwapRouter) {
        return IUniswapV3SwapRouter(swapRouter);
    }

    function _validateAndEncodeSwapPath(
        address[] calldata swapPath,
        uint24[] calldata swapFees,
        address collateralToken,
        address borrowToken
    ) internal pure returns (bytes memory encodedSwapPath) {
        StrataxUniswapLib.validateSwapPath(swapPath, swapFees, collateralToken, borrowToken);
        return StrataxUniswapLib.encodeSwapPath(swapPath, swapFees);
    }
}
