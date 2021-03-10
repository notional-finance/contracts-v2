// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../common/FreeCollateral.sol";
import "../../storage/AccountContextHandler.sol";

library FreeCollateralExternal {
    using AccountContextHandler for AccountStorage;

    function getFreeCollateral(
        address account
    ) external view returns (int) {

    }

    function checkFreeCollateralAndRevert(
        address account,
        bool loadPortfolio // TODO: switch this in v2
    ) external {
        // Load account context
        // TODO: load this
        AccountStorage memory accountContext;
        // load all balances
        BalanceState[] memory balanceStates = accountContext.getAllBalances(account);

        PortfolioState memory portfolioState;
        if (loadPortfolio) {
            // if required, load portfolio
            portfolioState = PortfolioHandler.buildPortfolioState(account, 0);
        }

        (
            /* allActiveAssets */,
            int[] memory netPortfolioValue,
            CashGroupParameters[] memory cashGroups,
            /* marketStates */
        ) = FreeCollateral.setupFreeCollateralStateful(portfolioState, block.timestamp);

        int ethDenominatedFC = FreeCollateral.getFreeCollateralStateful(balanceStates, cashGroups, netPortfolioValue);
        require(ethDenominatedFC >= 0, "Insufficient free collateral");
    }

}