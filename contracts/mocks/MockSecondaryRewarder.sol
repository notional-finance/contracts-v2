// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;

import "interfaces/notional/IRewarder.sol";

contract MockSecondaryRewarder is IRewarder {

    event ClaimRewards(address account, uint256 nTokenBalanceBefore, uint256 nTokenBalanceAfter, int256 netNTokenSupplyChange, uint256 NOTETokensClaimed);

    function claimRewards(
        address account,
        uint16 currencyId,
        uint256 nTokenBalanceBefore,
        uint256 nTokenBalanceAfter,
        int256 netNTokenSupplyChange,
        uint256 NOTETokensClaimed
    ) external override {
        emit ClaimRewards(account, nTokenBalanceBefore, nTokenBalanceAfter, netNTokenSupplyChange, NOTETokensClaimed);
    }

}