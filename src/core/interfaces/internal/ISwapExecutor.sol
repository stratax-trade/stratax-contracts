// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface ISwapExecutor {
    /**
     * @notice Execute a swap with normalized semantics across DEXes
     * @param swapRouter The DEX router/aggregator address
     * @param inputToken Token being sold
     * @param outputToken Token being bought
     * @param inputAmount Amount of inputToken to swap
     * @param swapData Encoded swap calldata (DEX-specific routing/path)
     * @param minOutputAmount Minimum acceptable outputToken amount (slippage protection)
     * @return outputAmount Actual amount of outputToken received
     */
    function executeSwap(
        address swapRouter,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        bytes calldata swapData,
        uint256 minOutputAmount
    ) external returns (uint256 outputAmount);

    /**
     * @notice Validate that a token pair is supported by this executor
     * @param tokenA First token
     * @param tokenB Second token
     * @param config Protocol-specific configuration (e.g., pool fee)
     * @return isValid True if token pair is valid
     */
    function validateTokenPair(address tokenA, address tokenB, bytes calldata config)
        external
        view
        returns (bool isValid);
}
