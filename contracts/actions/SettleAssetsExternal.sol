// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/PortfolioHandler.sol";
import "../storage/BalanceHandler.sol";
import "../storage/SettleAssets.sol";
import "../storage/AccountContextHandler.sol";

library SettleAssetsExternal {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;
    
    // TODO: can this be a static call?
    function settleAssetsView(
        address account,
        uint blockTime
    ) external view returns (PortfolioState memory, SettleAmount[] memory) {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory portfolioState = PortfolioHandler.buildPortfolioState(
            account, accountContext.assetArrayLength, 0);
        SettleAmount[] memory settleAmounts = SettleAssets.getSettleAssetContextView(portfolioState, blockTime);

        return (portfolioState, settleAmounts);
    }

    // TODO: can this be a static call?
    function settleBitmappedAccountView(
        address account,
        uint currencyId,
        uint nextSettleTime,
        uint blockTime
    ) external view returns (int) {
        PortfolioAsset[] memory ifCashAssets = BitmapAssetsHandler.getifCashArray(account, currencyId, nextSettleTime);

        PortfolioState memory portfolioState = PortfolioState({
            storedAssets: ifCashAssets,
            newAssets: new PortfolioAsset[](0),
            lastNewAssetIndex: 0,
            storedAssetLength: ifCashAssets.length
        });


        SettleAmount[] memory settleAmounts = SettleAssets.getSettleAssetContextView(portfolioState, blockTime);

        return settleAmounts[0].netCashChange;
    }

    function settleAssetsAndFinalize(address account) external returns (AccountStorage memory) {
        (
            AccountStorage memory accountContext,
            /* SettleAmount[] memory settleAmounts */,
            /* portfolioState */
        ) = _settleAccount(account, true, true);

        return accountContext;
    }

    function settleAssetsAndStorePortfolio(
        address account
    ) external returns (AccountStorage memory, SettleAmount[] memory) {
        (
            AccountStorage memory accountContext,
            SettleAmount[] memory settleAmounts,
            /* portfolioState */
        ) = _settleAccount(account, true, false);

        return (accountContext, settleAmounts);
    }

    function settleAssetsAndReturnPortfolio(
        address account
    ) external returns (AccountStorage memory, PortfolioState memory) {
        (
            AccountStorage memory accountContext,
            /* SettleAmount[] memory settleAmounts */,
            PortfolioState memory portfolioState
        ) = _settleAccount(account, true, false);

        return (accountContext, portfolioState);
    }

    function settleAssetsAndReturnAll(
        address account
    ) external returns (AccountStorage memory, SettleAmount[] memory, PortfolioState memory) {
        return _settleAccount(account, false, false);
    }

    function _settleAccount(
        address account,
        bool finalizePortfolio,
        bool finalizeAmounts
    ) internal returns (AccountStorage memory, SettleAmount[] memory, PortfolioState memory) {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        SettleAmount[] memory settleAmounts;
        PortfolioState memory portfolioState;

        if (accountContext.bitmapCurrencyId != 0) {
            settleAmounts = settleBitmappedAccountStateful(
                account,
                accountContext.bitmapCurrencyId,
                accountContext.nextSettleTime
            );
        } else {
            portfolioState = PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);
            settleAmounts = SettleAssets.getSettleAssetContextStateful(portfolioState, block.timestamp);
            if (finalizePortfolio) accountContext.storeAssetsAndUpdateContext(account, portfolioState);
        }
        
        if (finalizeAmounts) BalanceHandler.finalizeSettleAmounts(account, accountContext, settleAmounts);

        return (accountContext, settleAmounts, portfolioState);
    }

    function settleBitmappedAccountStateful(
        address account,
        uint currencyId,
        uint nextSettleTime
    ) internal returns (SettleAmount[] memory) {
        (bytes32 assetsBitmap, int settledCash) = SettleAssets.settleBitmappedCashGroup(
            account,
            currencyId,
            nextSettleTime,
            block.timestamp
        );

        BitmapAssetsHandler.setAssetsBitmap(account, currencyId, assetsBitmap);
        SettleAmount[] memory settleAmounts = new SettleAmount[](1);
        settleAmounts[0].currencyId = currencyId;
        settleAmounts[0].netCashChange = settledCash;
        return settleAmounts;
    }
}