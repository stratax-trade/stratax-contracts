// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ISwapExecutor} from "../interfaces/internal/ISwapExecutor.sol";

interface IOneInchSwapCaller {
    function executeOneInchSwapFromPosition(
        address swapRouter,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        bytes calldata swapData,
        uint256 minOutputAmount
    ) external returns (uint256 outputAmount);
}

/**
 * @title OneInchExecutor
 * @notice Normalized swap executor for 1Inch
 */
contract OneInchExecutor is ISwapExecutor {
    function executeSwap(
        address swapRouter,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        bytes calldata swapData,
        uint256 minOutputAmount
    ) external override returns (uint256 outputAmount) {
        require(inputAmount > 0, "Trade size must be greater than zero");

        // 1Inch calldata is bound to the position proxy as sender. Execute the router call
        // from the position context to preserve that sender expectation.
        return IOneInchSwapCaller(msg.sender)
            .executeOneInchSwapFromPosition(swapRouter, inputToken, outputToken, inputAmount, swapData, minOutputAmount);
    }

    function validateTokenPair(address tokenA, address tokenB, bytes calldata config)
        external
        pure
        override
        returns (bool isValid)
    {
        config;
        // 1Inch supports any token pair; validation at adapter level
        return tokenA != address(0) && tokenB != address(0) && tokenA != tokenB;
    }
}
