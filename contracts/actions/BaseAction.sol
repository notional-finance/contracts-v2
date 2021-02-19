// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/BalanceHandler.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/SettleAssets.sol";
import "../common/Market.sol";
import "../math/Bitmap.sol";

abstract contract BaseAction is SettleAssets {
    using BalanceHandler for BalanceState;
    using PortfolioHandler for PortfolioState;
    using Market for MarketParameters;
    using Bitmap for bytes;

    function _beforeAction(
        address account,
        uint newAssetsHint,
        uint blockTime
    ) private view returns (AccountStorage memory, PortfolioState memory) {
        // Storage Read
        AccountStorage memory accountContext = accountContextMapping[account];
        PortfolioState memory portfolioState;

        if (accountContext.nextMaturingAsset <= blockTime || newAssetsHint > 0) {
            // We only fetch the portfolio state if there will be new assets added or if the account
            // must be settled.
            portfolioState = PortfolioHandler.buildPortfolioState(account, newAssetsHint);
        }

        return (accountContext, portfolioState);
    }

    function _beforeActionView(
        address account,
        uint newAssetsHint,
        uint blockTime
    ) internal view returns (
        AccountStorage memory,
        PortfolioState memory,
        BalanceState[] memory
    ) {
        (
            AccountStorage memory accountContext,
            PortfolioState memory portfolioState
        ) = _beforeAction(account, newAssetsHint, blockTime);
        BalanceState[] memory balanceState;

        if (accountContext.nextMaturingAsset <= blockTime) {
            if (accountContext.hasBitmap) {
                // TODO: For a view, read bitmap into portfolio state
            }

            // This means that settlement is required
            balanceState = getSettleAssetContextView(
                account,
                portfolioState,
                accountContext,
                blockTime
            );

        }

        return (accountContext, portfolioState, balanceState);
    }

    function _beforeActionStateful(
        address account,
        uint newAssetsHint,
        uint blockTime
    ) internal returns (
        AccountStorage memory,
        PortfolioState memory,
        BalanceState[] memory
    ) {
        (
            AccountStorage memory accountContext,
            PortfolioState memory portfolioState
        ) = _beforeAction(account, newAssetsHint, blockTime);
        BalanceState[] memory balanceState;

        if (accountContext.nextMaturingAsset <= blockTime) {
            // This means that settlement is required
            balanceState = getSettleAssetContextStateful(
                account,
                portfolioState,
                accountContext,
                blockTime
            );

            if (accountContext.hasBitmap) {
                // TODO: settle bitmap
            }

        }

        return (accountContext, portfolioState, balanceState);
    }

    function _finalizeState(
        address account,
        AccountStorage memory accountContext,
        PortfolioState memory portfolioState,
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates,
        uint blockTime
    ) internal {
        AssetStorage[] storage assetStoragePointer = assetArrayMapping[account];
        // Store balances and portfolio state
        portfolioState.storeAssets(assetStoragePointer);

        bytes memory activeCurrenciesCopy = accountContext.activeCurrencies.copy();
        for (uint i; i < balanceState.length; i++) {
            balanceState[i].finalize(account, accountContext);
        }

        // Finalizing markets will always update to the current settlement date.
        uint settlementDate = CashGroup.getReferenceTime(blockTime) + CashGroup.QUARTER;
        for (uint i; i < marketStates.length; i++) {
            for (uint j; j < marketStates[i].length; j++) {
                if (!marketStates[i][j].hasUpdated) continue;
                marketStates[i][j].setMarketStorage(settlementDate);
            }
        }

        accountContext = _finalizeView(
            account,
            accountContext,
            portfolioState,
            balanceState,
            cashGroups,
            marketStates,
            activeCurrenciesCopy,
            blockTime
        );

        accountContextMapping[account] = accountContext;
    }

    function _finalizeView(
        address account,
        AccountStorage memory accountContext,
        PortfolioState memory portfolioState,
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates,
        bytes memory activeCurrencies,
        uint blockTime
    ) internal view virtual returns (AccountStorage memory) {
        // TODO: need to make sure all the context variables are set properly here
        return accountContext;
    }
}