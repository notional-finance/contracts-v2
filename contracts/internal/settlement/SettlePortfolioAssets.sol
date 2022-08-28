// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../valuation/AssetHandler.sol";
import "../markets/Market.sol";
import "../markets/AssetRate.sol";
import "../portfolio/PortfolioHandler.sol";
import "../../math/SafeInt256.sol";
import "../../global/Constants.sol";
import "../../global/Types.sol";

library SettlePortfolioAssets {
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;
    using Market for MarketParameters;
    using PortfolioHandler for PortfolioState;
    using AssetHandler for PortfolioAsset;

    /// @dev Returns a SettleAmount array for the assets that will be settled
    function _getSettleAmountArray(PortfolioState memory portfolioState, uint256 blockTime)
        private
        pure
        returns (SettleAmount[] memory)
    {
        uint256 currenciesSettled;
        uint256 lastCurrencyId = 0;
        if (portfolioState.storedAssets.length == 0) return new SettleAmount[](0);

        // Loop backwards so "lastCurrencyId" will be set to the first currency in the portfolio
        // NOTE: if this contract is ever upgraded to Solidity 0.8+ then this i-- will underflow and cause
        // a revert, must wrap in an unchecked.
        for (uint256 i = portfolioState.storedAssets.length; (i--) > 0;) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            // Assets settle on exactly blockTime
            if (asset.getSettlementDate() > blockTime) continue;

            // Assume that this is sorted by cash group and maturity, currencyId = 0 is unused so this
            // will work for the first asset
            if (lastCurrencyId != asset.currencyId) {
                lastCurrencyId = asset.currencyId;
                currenciesSettled++;
            }
        }

        // Actual currency ids will be set as we loop through the portfolio and settle assets
        SettleAmount[] memory settleAmounts = new SettleAmount[](currenciesSettled);
        if (currenciesSettled > 0) settleAmounts[0].currencyId = lastCurrencyId;
        return settleAmounts;
    }

    /// @notice Settles a portfolio array
    function settlePortfolio(PortfolioState memory portfolioState, uint256 blockTime)
        internal
        returns (SettleAmount[] memory)
    {
        AssetRateParameters memory settlementRate;
        SettleAmount[] memory settleAmounts = _getSettleAmountArray(portfolioState, blockTime);
        MarketParameters memory market;
        if (settleAmounts.length == 0) return settleAmounts;
        uint256 settleAmountIndex;

        for (uint256 i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            uint256 settleDate = asset.getSettlementDate();
            // Settlement date is on block time exactly
            if (settleDate > blockTime) continue;

            // On the first loop the lastCurrencyId is already set.
            if (settleAmounts[settleAmountIndex].currencyId != asset.currencyId) {
                // New currency in the portfolio
                settleAmountIndex += 1;
                settleAmounts[settleAmountIndex].currencyId = asset.currencyId;
            }

            int256 assetCash;
            if (asset.assetType == Constants.FCASH_ASSET_TYPE) {
                // Gets or sets the settlement rate, only do this before settling fCash
                settlementRate = AssetRate.buildSettlementRateStateful(
                    asset.currencyId,
                    asset.maturity,
                    blockTime
                );

                assetCash = settlementRate.convertFromUnderlying(asset.notional);
                portfolioState.deleteAsset(i);
            } else if (AssetHandler.isLiquidityToken(asset.assetType)) {
                Market.loadSettlementMarket(market, asset.currencyId, asset.maturity, settleDate);
                int256 fCash;
                (assetCash, fCash) = market.removeLiquidity(asset.notional);

                // Assets mature exactly on block time
                if (asset.maturity > blockTime) {
                    // If fCash has not yet matured then add it to the portfolio
                    _settleLiquidityTokenTofCash(portfolioState, i, fCash);
                } else {
                    // Gets or sets the settlement rate, only do this before settling fCash
                    settlementRate = AssetRate.buildSettlementRateStateful(
                        asset.currencyId,
                        asset.maturity,
                        blockTime
                    );

                    // If asset has matured then settle fCash to asset cash
                    assetCash = assetCash.add(settlementRate.convertFromUnderlying(fCash));
                    portfolioState.deleteAsset(i);
                }
            }
            settleAmounts[settleAmountIndex].netCashChange = settleAmounts[settleAmountIndex]
                .netCashChange
                .add(assetCash);
        }

        return settleAmounts;
    }

    /// @notice Settles a liquidity token to idiosyncratic fCash, this occurs when the maturity is still in the future
    function _settleLiquidityTokenTofCash(
        PortfolioState memory portfolioState,
        uint256 index,
        int256 fCash
    ) private pure {
        PortfolioAsset memory liquidityToken = portfolioState.storedAssets[index];
        // If the liquidity token's maturity is still in the future then we change the entry to be
        // an idiosyncratic fCash entry with the net fCash amount.
        if (index != 0) {
            // Check to see if the previous index is the matching fCash asset, this will be the case when the
            // portfolio is sorted
            PortfolioAsset memory fCashAsset = portfolioState.storedAssets[index - 1];

            if (
                fCashAsset.currencyId == liquidityToken.currencyId &&
                fCashAsset.maturity == liquidityToken.maturity &&
                fCashAsset.assetType == Constants.FCASH_ASSET_TYPE
            ) {
                // This fCash asset has not matured if we are settling to fCash
                fCashAsset.notional = fCashAsset.notional.add(fCash);
                fCashAsset.storageState = AssetStorageState.Update;
                portfolioState.deleteAsset(index);
            }
        }

        // We are going to delete this asset anyway, convert to an fCash position
        liquidityToken.assetType = Constants.FCASH_ASSET_TYPE;
        liquidityToken.notional = fCash;
        liquidityToken.storageState = AssetStorageState.Update;
    }
}
