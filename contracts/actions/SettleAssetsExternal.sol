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

    function settleAssetsAndFinalize(address account) external returns (AccountStorage memory) {
        (
            AccountStorage memory accountContext,
            SettleAmount[] memory settleAmounts,
            PortfolioState memory portfolioState
        ) = _settleAssetsArray(account);

        accountContext.storeAssetsAndUpdateContext(account, portfolioState);
        BalanceHandler.finalizeSettleAmounts(account, accountContext, settleAmounts);

        return accountContext;
    }

    function settleAssetsAndStorePortfolio(
        address account
    ) external returns (AccountStorage memory, SettleAmount[] memory) {
        (
            AccountStorage memory accountContext,
            SettleAmount[] memory settleAmounts,
            PortfolioState memory portfolioState
        ) = _settleAssetsArray(account);
        accountContext.storeAssetsAndUpdateContext(account, portfolioState);

        return (accountContext, settleAmounts);
    }

    function settleAssetsAndReturnPortfolio(
        address account
    ) external returns (AccountStorage memory, SettleAmount[] memory, PortfolioState memory) {
        return _settleAssetsArray(account);
    }

    function _settleAssetsArray(
        address account
    ) internal returns (AccountStorage memory, SettleAmount[] memory, PortfolioState memory) {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory portfolioState = PortfolioHandler.buildPortfolioState(
            account, accountContext.assetArrayLength, 0);
        SettleAmount[] memory settleAmounts = SettleAssets.getSettleAssetContextStateful(portfolioState, block.timestamp);

        return (accountContext, settleAmounts, portfolioState);
    }

    function settleBitmappedAccountView(
        address account,
        uint currencyId,
        uint nextSettleTime,
        uint blockTime
    ) external view returns (int) {
        PortfolioAsset[] memory ifCashAssets = BitmapAssetsHandler.getifCashArray(account, currencyId, nextSettleTime);
        uint[] memory sortedIndex = new uint[](ifCashAssets.length);
        // ifCash assets are already sorted
        for (uint i; i < sortedIndex.length; i++) sortedIndex[i] = i;

        PortfolioState memory portfolioState = PortfolioState({
            storedAssets: ifCashAssets,
            newAssets: new PortfolioAsset[](0),
            lastNewAssetIndex: 0,
            storedAssetLength: ifCashAssets.length
        });


        SettleAmount[] memory settleAmounts = SettleAssets.getSettleAssetContextView(portfolioState, blockTime);

        return settleAmounts[0].netCashChange;
    }

    function settleBitmappedAccountStateful(
        address account,
        uint currencyId,
        uint nextSettleTime
    ) external returns (bytes32, int) {
        return SettleAssets.settleBitmappedCashGroup(
            account,
            currencyId,
            nextSettleTime,
            block.timestamp
        );
    }
}