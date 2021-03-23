// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/FreeCollateral.sol";
import "../storage/AccountContextHandler.sol";

library FreeCollateralExternal {
    using AccountContextHandler for AccountStorage;

    function getFreeCollateralView(address account) external view returns (int) {
        uint blockTime = block.timestamp;
        int[] memory netPortfolioValue;
        CashGroupParameters[] memory cashGroups;
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);

        if (accountContext.bitmapCurrencyId == 0) {
            (netPortfolioValue, cashGroups) = FreeCollateral.getNetPortfolioValueView(account, accountContext, blockTime);
        } else {
            cashGroups = new CashGroupParameters[](1);
            MarketParameters[] memory markets;
            (cashGroups[0], markets) = CashGroup.buildCashGroupView(accountContext.bitmapCurrencyId);
            netPortfolioValue = new int[](1);
            bytes32 assetsBitmap = BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId);
            (netPortfolioValue[0], /* hasDebt */) = BitmapAssetsHandler.getifCashNetPresentValue(
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

    function checkFreeCollateralAndRevert(address account) external {
        uint blockTime = block.timestamp;
        int[] memory netPortfolioValue;
        CashGroupParameters[] memory cashGroups;
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);

        if (accountContext.bitmapCurrencyId == 0) {
            (netPortfolioValue, cashGroups) = FreeCollateral.getNetPortfolioValueStateful(account, accountContext, blockTime);
        } else {
            cashGroups = new CashGroupParameters[](1);
            MarketParameters[] memory markets;
            (cashGroups[0], markets) = CashGroup.buildCashGroupStateful(accountContext.bitmapCurrencyId);
            netPortfolioValue = new int[](1);
            bytes32 assetsBitmap = BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId);
            bool bitmapHasDebt;
            (netPortfolioValue[0], bitmapHasDebt) = BitmapAssetsHandler.getifCashNetPresentValue(
                account,
                accountContext.bitmapCurrencyId,
                accountContext.nextSettleTime,
                blockTime,
                assetsBitmap,
                cashGroups[0],
                markets,
                true // risk adjusted
            );

            // Turns off has debt flag if it has changed
            bool contextHasAssetDebt = accountContext.hasDebt & AccountContextHandler.HAS_ASSET_DEBT == AccountContextHandler.HAS_ASSET_DEBT;
            if (bitmapHasDebt && !contextHasAssetDebt) {
                accountContext.hasDebt = accountContext.hasDebt | AccountContextHandler.HAS_ASSET_DEBT;
                accountContext.setAccountContext(account);
            } else if (!bitmapHasDebt && contextHasAssetDebt) {
                accountContext.hasDebt = accountContext.hasDebt & ~AccountContextHandler.HAS_ASSET_DEBT;
                accountContext.setAccountContext(account);
            }
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