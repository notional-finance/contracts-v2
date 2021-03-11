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
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState[] memory balanceStates = accountContext.getAllBalances(account);
        uint blockTime = block.timestamp;

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
        ) = FreeCollateral.setupFreeCollateralStateful(portfolioState, blockTime);

        int ethDenominatedFC = FreeCollateral.getFreeCollateralStateful(
            balanceStates,
            cashGroups,
            netPortfolioValue,
            blockTime
        );

        require(ethDenominatedFC >= 0, "Insufficient free collateral");
    }

}