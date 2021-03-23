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
        int[] memory netPortfolioValue;
        CashGroupParameters[] memory cashGroups;

        if (accountContext.bitmapCurrencyId == 0) {
            (netPortfolioValue, cashGroups) = FreeCollateral.getNetPortfolioValueView(account, accountContext, blockTime);
        } else {
            cashGroups = new CashGroupParameters[](1);
            MarketParameters[] memory markets;
            (cashGroups[0], markets) = CashGroup.buildCashGroupView(accountContext.bitmapCurrencyId);
            netPortfolioValue = new int[](1);
            bytes32 assetsBitmap = BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId);
            netPortfolioValue[0] = BitmapAssetsHandler.getifCashNetPresentValue(
                account,
                accountContext.bitmapCurrencyId,
                accountContext.nextSettleTime,
                blockTime,
                assetsBitmap,
                cashGroups[0],
                markets,
                true // risk adjusted
            );
        }

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
        int[] memory netPortfolioValue;
        CashGroupParameters[] memory cashGroups;

        if (accountContext.bitmapCurrencyId == 0) {
            (netPortfolioValue, cashGroups) = FreeCollateral.getNetPortfolioValueStateful(account, accountContext, blockTime);
        } else {
            cashGroups = new CashGroupParameters[](1);
            MarketParameters[] memory markets;
            (cashGroups[0], markets) = CashGroup.buildCashGroupStateful(accountContext.bitmapCurrencyId);
            netPortfolioValue = new int[](1);
            bytes32 assetsBitmap = BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId);
            netPortfolioValue[0] = BitmapAssetsHandler.getifCashNetPresentValue(
                account,
                accountContext.bitmapCurrencyId,
                accountContext.nextSettleTime,
                blockTime,
                assetsBitmap,
                cashGroups[0],
                markets,
                true // risk adjusted
            );
        }


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