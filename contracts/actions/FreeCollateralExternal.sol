// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/FreeCollateral.sol";
import "../storage/AccountContextHandler.sol";

library FreeCollateralExternal {
    using AccountContextHandler for AccountStorage;

    function getFreeCollateralView(address account) external view returns (int) {
        uint blockTime = block.timestamp;
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState[] memory balanceStates = accountContext.getAllBalances(account);

        (
            int[] memory netPortfolioValue,
            CashGroupParameters[] memory cashGroups
        ) = FreeCollateral.getNetPortfolioValueView(account, accountContext, blockTime);

        return FreeCollateral.getFreeCollateralView(
            balanceStates,
            cashGroups,
            netPortfolioValue,
            blockTime
        );
    }

    function checkFreeCollateralAndRevert(address account) external {
        uint blockTime = block.timestamp;
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState[] memory balanceStates = accountContext.getAllBalances(account);

        (
            int[] memory netPortfolioValue,
            CashGroupParameters[] memory cashGroups
        ) = FreeCollateral.getNetPortfolioValueStateful(account, accountContext, blockTime);

        int ethDenominatedFC = FreeCollateral.getFreeCollateralStateful(
            balanceStates,
            cashGroups,
            netPortfolioValue,
            blockTime
        );

        require(ethDenominatedFC >= 0, "Insufficient free collateral");
    }

}