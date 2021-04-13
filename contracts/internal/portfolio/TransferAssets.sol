// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../actions/SettleAssetsExternal.sol";
import "./PortfolioHandler.sol";
import "./BitmapAssetsHandler.sol";
import "../AccountContextHandler.sol";

library TransferAssets {
    using AccountContextHandler for AccountStorage;
    using PortfolioHandler for PortfolioState;
    using SafeInt256 for int256;

    function invertNotionalAmountsInPlace(PortfolioAsset[] memory assets) internal pure {
        for (uint256 i; i < assets.length; i++) {
            assets[i].notional = assets[i].notional.neg();
        }
    }

    function placeAssetsInAccount(
        address account,
        AccountStorage memory accountContext,
        PortfolioAsset[] memory assets
    ) internal {
        if (accountContext.bitmapCurrencyId == 0) {
            addAssetsToPortfolio(account, accountContext, assets);
        } else {
            addAssetsToBitmap(account, accountContext, assets);
        }
    }

    function addAssetsToPortfolio(
        address account,
        AccountStorage memory accountContext,
        PortfolioAsset[] memory assets
    ) internal {
        PortfolioState memory portfolioState;
        if (accountContext.mustSettleAssets()) {
            (accountContext, portfolioState) = SettleAssetsExternal.settleAssetsAndReturnPortfolio(
                account
            );
        } else {
            portfolioState = PortfolioHandler.buildPortfolioState(
                account,
                accountContext.assetArrayLength,
                assets.length
            );
        }

        portfolioState.addMultipleAssets(assets);
        accountContext.storeAssetsAndUpdateContext(account, portfolioState);
    }

    function addAssetsToBitmap(
        address account,
        AccountStorage memory accountContext,
        PortfolioAsset[] memory assets
    ) internal {
        if (accountContext.mustSettleAssets()) {
            SettleAssetsExternal.settleAssetsAndFinalize(account);
        }

        BitmapAssetsHandler.addMultipleifCashAssets(account, accountContext, assets);
    }
}
