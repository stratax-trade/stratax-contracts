// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IUniswapV3SwapRouter} from "../../interfaces/external/IUniswapV3SwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library StrataxUniswapLib {
    struct InitParams {
        address uniswapRouter;
    }

    struct Config {
        address router;
        address quoter;
        uint24 poolFee;
    }

    function decodeConfig(bytes memory configData) internal pure returns (Config memory config) {
        require(configData.length > 0, "Missing uniswap config");
        config = abi.decode(configData, (Config));
    }

    function hasValidCoreConfig(Config memory config) internal pure returns (bool) {
        return config.router != address(0) && config.quoter != address(0) && config.poolFee > 0;
    }

    function validateTokenPair(address collateralToken, address borrowToken, bytes memory configData)
        internal
        pure
        returns (bool isValid)
    {
        if (collateralToken == address(0) || borrowToken == address(0)) {
            return false;
        }

        if (collateralToken == borrowToken) {
            return false;
        }

        Config memory config = decodeConfig(configData);
        return hasValidCoreConfig(config);
    }

    /**
     * @dev Validates that a swap path is well-formed and that its source and destination
     *      tokens are the position's collateral or borrow token.
     */
    function validateSwapPath(
        address[] calldata swapPath,
        uint24[] calldata swapFees,
        address collateralToken,
        address borrowToken
    ) internal pure {
        require(swapPath.length >= 2, "Swap path must have at least 2 tokens");
        require(swapFees.length == swapPath.length - 1, "swapFees length mismatch");

        address src = swapPath[0];
        address dst = swapPath[swapPath.length - 1];

        require(src == collateralToken || src == borrowToken, "Source token must be collateral or borrow token");
        require(dst == collateralToken || dst == borrowToken, "Destination token must be collateral or borrow token");
        require(src != dst, "Source and destination tokens must differ");
    }

    /**
     * @dev Encodes a Uniswap V3 multi-hop path from an ordered token array and fee tiers.
     *      Encoding: abi.encodePacked(token0, fee0, token1, fee1, ..., tokenN)
     */
    function encodeSwapPath(address[] calldata swapPath, uint24[] calldata swapFees)
        internal
        pure
        returns (bytes memory path)
    {
        path = abi.encodePacked(swapPath[0]);
        for (uint256 i = 0; i < swapFees.length; i++) {
            path = abi.encodePacked(path, swapFees[i], swapPath[i + 1]);
        }
    }

    /**
     * @dev Executes a Uniswap V3 exact input swap (supports single-hop and multi-hop paths).
     * @param router The Uniswap V3 swap router
     * @param swapPath ABI-packed swap path: token0 ++ fee0 ++ token1 [++ fee1 ++ token2 ...]
     * @param amountIn Token amount to swap in
     * @param minAmountOut Minimum acceptable output (slippage protection)
     */
    function swapExactInput(IUniswapV3SwapRouter router, bytes memory swapPath, uint256 amountIn, uint256 minAmountOut)
        internal
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "Invalid amount in");
        require(swapPath.length >= 43, "Invalid swap path");

        // Extract tokenOut from the last 20 bytes of the encoded path.
        address tokenOut;
        assembly {
            tokenOut := shr(96, mload(add(add(swapPath, 0x20), sub(mload(swapPath), 20))))
        }

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        IUniswapV3SwapRouter.ExactInputParams memory swapParams = IUniswapV3SwapRouter.ExactInputParams({
            path: swapPath,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut
        });

        amountOut = router.exactInput(swapParams);
        require(amountOut >= minAmountOut, "Insufficient return amount from swap");

        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        require(balanceAfter > balanceBefore, "Destination token not received");
    }

    /// @notice Decodes encoded swap config and builds InitParams for position contract initialization.
    function buildSwapInitParams(bytes memory configData) internal pure returns (InitParams memory params) {
        Config memory config = decodeConfig(configData);
        params = InitParams({uniswapRouter: config.router});
    }
}
