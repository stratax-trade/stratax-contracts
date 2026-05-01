// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ISwapExecutor} from "../interfaces/internal/ISwapExecutor.sol";
import {IUniswapV3SwapRouter} from "../../interfaces/external/IUniswapV3SwapRouter.sol";
import {StrataxUniswapLib} from "../../libraries/swapping/StrataxUniswapLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title UniswapV3Executor
 * @notice Normalized swap executor for Uniswap V3
 */
contract UniswapV3Executor is ISwapExecutor {
    using SafeERC20 for IERC20;

    function executeSwap(
        address swapRouter,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        bytes calldata swapData,
        uint256 minOutputAmount
    ) external override returns (uint256 outputAmount) {
        require(inputAmount > 0, "Trade size must be greater than zero");

        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
        IERC20(inputToken).forceApprove(swapRouter, inputAmount);

        // swapData is the encoded path + fees
        outputAmount =
            StrataxUniswapLib.swapExactInput(IUniswapV3SwapRouter(swapRouter), swapData, inputAmount, minOutputAmount);

        IERC20(outputToken).safeTransfer(msg.sender, outputAmount);
    }

    function validateTokenPair(address tokenA, address tokenB, bytes calldata config)
        external
        pure
        override
        returns (bool isValid)
    {
        // Uniswap V3 supports any token pair; config validation can be done at adapter level
        return tokenA != address(0) && tokenB != address(0) && tokenA != tokenB;
    }
}
