
// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/FreeCollateral.sol";
import "../storage/AccountContextHandler.sol";
import "./BaseAction.sol";

abstract contract BaseActionWithFC is BaseAction {
    using BalanceHandler for BalanceState;
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;
    using Bitmap for bytes;

    function _finalizeView(
        address account,
        AccountStorage memory accountContext,
        PortfolioState memory portfolioState,
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates,
        uint blockTime
    ) internal view override returns (AccountStorage memory) {
        accountContext.hasDebt = FreeCollateral.shouldCheckFreeCollateral(
            accountContext,
            balanceState,
            portfolioState
        );

        if (accountContext.hasDebt) {
            // After storage the sorted index must be recalculated but we do this again in the view just
            // to be safe since there are no gas costs.
            portfolioState.calculateSortedIndex();

            // Get remaining balances that have not changed, all balances is an ordered array of the
            // currency ids. This is the same ordering that portfolioState.storedAssets and newAssets
            // are also stored in.
            // TODO: this does not contain assets that do not have cash balances, ensure that
            // trading will result in a balance entering the context
            balanceState = accountContext.getAllBalances(account);

            require(FreeCollateral.doesAccountPassFreeCollateral(
                account,
                accountContext,
                portfolioState,
                balanceState,
                cashGroups,
                marketStates,
                blockTime
            ), "Insufficient free collateral");
        }

        // TODO: need to make sure all the context variables are set properly here
        return accountContext;
    }
}