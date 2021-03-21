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

        (
            int[] memory netPortfolioValue,
            CashGroupParameters[] memory cashGroups
        ) = FreeCollateral.getNetPortfolioValueView(account, accountContext, blockTime);

        return FreeCollateral.getFreeCollateralView(
            account,
            accountContext,
            cashGroups,
            netPortfolioValue,
            blockTime
        );
    }

    // TODO: have this return hasDebt for the bitmapped portfolio
    function checkFreeCollateralAndRevert(address account) external {
        uint blockTime = block.timestamp;
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);

        (
            int[] memory netPortfolioValue,
            CashGroupParameters[] memory cashGroups
        ) = FreeCollateral.getNetPortfolioValueStateful(account, accountContext, blockTime);

        int ethDenominatedFC = FreeCollateral.getFreeCollateralStateful(
            account,
            accountContext,
            cashGroups,
            netPortfolioValue,
            blockTime
        );

        require(ethDenominatedFC >= 0, "Insufficient free collateral");
    }

}