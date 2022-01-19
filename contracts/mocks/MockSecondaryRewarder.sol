// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

contract MockSecondaryRewarder {

    event ClaimRewards(address account, uint256 nTokenBalanceBefore, uint256 nTokenBalanceAfter, uint256 NOTETokensClaimed);

    function claimRewards(
        address account,
        uint256 nTokenBalanceBefore,
        uint256 nTokenBalanceAfter,
        uint256 NOTETokensClaimed
    ) external {
        emit ClaimRewards(account, nTokenBalanceBefore, nTokenBalanceAfter, NOTETokensClaimed);
    }

}