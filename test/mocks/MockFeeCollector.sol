// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFeeCollector {
    address[] private _trackedTokens;
    mapping(address => bool) public isTracked;
    mapping(address => uint256) public pendingRewards;

    function addTrackedToken(address token) external {
        if (!isTracked[token]) {
            isTracked[token] = true;
            _trackedTokens.push(token);
        }
    }

    function setPendingReward(address token, uint256 amount) external {
        pendingRewards[token] = amount;
    }

    function getAllTrackedFeeTokens() external view returns (address[] memory tokens) {
        tokens = _trackedTokens;
    }

    function collectStakerRewardsForAllAssets() external {
        uint256 len = _trackedTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = _trackedTokens[i];
            uint256 amount = pendingRewards[token];
            if (amount == 0) {
                continue;
            }

            pendingRewards[token] = 0;
            IERC20(token).transfer(msg.sender, amount);
        }
    }
}
