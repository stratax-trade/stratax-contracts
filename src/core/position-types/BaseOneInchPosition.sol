// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ISwapExecutor} from "../interfaces/internal/ISwapExecutor.sol";

/**
 * @title BaseOneInchPosition
 * @notice Swap-only base for 1inch-backed positions.
 */
abstract contract BaseOneInchPosition {
    address public swapRouter;
    ISwapExecutor public swapExecutor;

    uint256[48] private __swapGap;

    function _initOneInchSwap(address _swapRouter, ISwapExecutor _swapExecutor) internal {
        require(_swapRouter != address(0), "Invalid swap router");
        require(address(_swapExecutor) != address(0), "Invalid swap executor");
        swapRouter = _swapRouter;
        swapExecutor = _swapExecutor;
    }

    function oneInchRouter() public view returns (address) {
        return swapRouter;
    }

    function extractSelector(bytes calldata data) external pure returns (bytes4 selector) {
        require(data.length >= 4, "Data too short");
        selector = bytes4(data[0:4]);
    }
}
