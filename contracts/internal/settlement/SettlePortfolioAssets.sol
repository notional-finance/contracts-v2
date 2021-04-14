// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../valuation/AssetHandler.sol";
import "../markets/AssetRate.sol";
import "../portfolio/PortfolioHandler.sol";
import "../../math/SafeInt256.sol";
import "../../global/Constants.sol";
import "../../global/Types.sol";

library SettlePortfolioAssets {
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;
    using PortfolioHandler for PortfolioState;
    using AssetHandler for PortfolioAsset;

    /// @dev Returns a SettleAmount array for the assets that will be settled
    function _getSettleAmountArray(PortfolioState memory portfolioState, uint256 blockTime)
        private
        pure
        returns (SettleAmount[] memory)
    {
        uint256 currenciesSettled;
        uint256 lastCurrencyId;
        if (portfolioState.storedAssets.length == 0) return new SettleAmount[](0);

        // Loop backwards so "lastCurrencyId" will be set to the first currency in the portfolio
        for (uint256 i = portfolioState.storedAssets.length - 1; i >= 0; i--) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.getSettlementDate() > blockTime) {
                if (i == 0) break;
                continue;
            }

            // Assume that this is sorted by cash group and maturity, currencyId = 0 is unused so this
            // will work for the first asset
            if (lastCurrencyId != asset.currencyId) {
                lastCurrencyId = asset.currencyId;
                currenciesSettled++;
            }

            // i-- will overflow and end up with index out of bounds error
            if (i == 0) break;
        }

        // Actual currency ids will be set in the loop
        SettleAmount[] memory settleAmounts = new SettleAmount[](currenciesSettled);
        if (currenciesSettled > 0) settleAmounts[0].currencyId = lastCurrencyId;
        return settleAmounts;
    }

    /// @notice Shared calculation for liquidity token settlement
    function _calculateMarketStorage(PortfolioAsset memory asset)
        private
        view
        returns (
            int256,
            int256,
            SettlementMarket memory
        )
    {
        SettlementMarket memory market =
            Market.getSettlementMarket(asset.currencyId, asset.maturity, asset.getSettlementDate());

        int256 assetCash = market.totalCurrentCash.mul(asset.notional).div(market.totalLiquidity);
        int256 fCash = market.totalfCash.mul(asset.notional).div(market.totalLiquidity);

        market.totalfCash = market.totalfCash.subNoNeg(fCash);
        market.totalCurrentCash = market.totalCurrentCash.subNoNeg(assetCash);
        market.totalLiquidity = market.totalLiquidity.subNoNeg(asset.notional);

        return (assetCash, fCash, market);
    }

    /// @notice Settles a liquidity token which requires getting the claims on both cash and fCash,
    /// converting the fCash portion to cash at the settlement rate.
    function _settleLiquidityToken(
        PortfolioAsset memory asset,
        AssetRateParameters memory settlementRate
    ) private view returns (int256, SettlementMarket memory) {
        (int256 assetCash, int256 fCash, SettlementMarket memory market) =
            _calculateMarketStorage(asset);

        assetCash = assetCash.add(settlementRate.convertFromUnderlying(fCash));
        return (assetCash, market);
    }

    /// @notice Settles a liquidity token to idiosyncratic fCash, this occurs when the maturity is still in the future
    function _settleLiquidityTokenTofCash(PortfolioState memory portfolioState, uint256 index)
        private
        view
        returns (int256, SettlementMarket memory)
    {
        PortfolioAsset memory liquidityToken = portfolioState.storedAssets[index];
        (int256 assetCash, int256 fCash, SettlementMarket memory market) =
            _calculateMarketStorage(liquidityToken);

        // If the liquidity token's maturity is still in the future then we change the entry to be
        // an idiosyncratic fCash entry with the net fCash amount.
        if (index != 0) {
            // Check to see if the previous index is the matching fCash asset, this will be the case when the
            // portfolio is sorted
            PortfolioAsset memory fCashAsset = portfolioState.storedAssets[index - 1];

            if (
                fCashAsset.maturity == liquidityToken.maturity &&
                fCashAsset.assetType == Constants.FCASH_ASSET_TYPE
            ) {
                // This fCash asset has not matured if were are settling to fCash
                fCashAsset.notional = fCashAsset.notional.add(fCash);
                fCashAsset.storageState = AssetStorageState.Update;

                portfolioState.deleteAsset(index);
                return (assetCash, market);
            }
        }

        liquidityToken.assetType = Constants.FCASH_ASSET_TYPE;
        liquidityToken.notional = fCash;
        liquidityToken.storageState = AssetStorageState.Update;

        return (assetCash, market);
    }

    /// @notice View version of settle asset with a call to getSettlementRateView, the reason here is that
    /// in the stateful version we will set the settlement rate if it is not set.
    function getSettleAssetContextView(PortfolioState memory portfolioState, uint256 blockTime)
        internal
        view
        returns (SettleAmount[] memory)
    {
        AssetRateParameters memory settlementRate;
        SettleAmount[] memory settleAmounts = _getSettleAmountArray(portfolioState, blockTime);
        if (settleAmounts.length == 0) return settleAmounts;
        uint256 settleAmountIndex;
        uint256 lastMaturity;

        for (uint256 i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.getSettlementDate() > blockTime) continue;

            if (settleAmounts[settleAmountIndex].currencyId != asset.currencyId) {
                lastMaturity = 0;
                settleAmountIndex += 1;
                require(settleAmountIndex < settleAmounts.length); // dev: settle amount index
                settleAmounts[settleAmountIndex].currencyId = asset.currencyId;
            }

            // Settlement rates are used to convert fCash and fCash claims back into assetCash values. This means
            // that settlement rates are required whenever fCash matures and when liquidity tokens' **fCash claims**
            // mature. fCash claims on liquidity tokens settle at asset.maturity, not the settlement date
            if (lastMaturity != asset.maturity && asset.maturity < blockTime) {
                // Storage Read inside getSettlementRateView
                settlementRate = AssetRate.buildSettlementRateView(
                    asset.currencyId,
                    asset.maturity
                );
                lastMaturity = asset.maturity;
            }

            int256 assetCash;
            if (asset.assetType == Constants.FCASH_ASSET_TYPE) {
                assetCash = settlementRate.convertFromUnderlying(asset.notional);
                portfolioState.deleteAsset(i);
            } else if (AssetHandler.isLiquidityToken(asset.assetType)) {
                if (asset.maturity > blockTime) {
                    (
                        assetCash, /* */

                    ) = _settleLiquidityTokenTofCash(portfolioState, i);
                } else {
                    (
                        assetCash, /* */

                    ) = _settleLiquidityToken(asset, settlementRate);
                    portfolioState.deleteAsset(i);
                }
            }

            settleAmounts[settleAmountIndex].netCashChange = settleAmounts[settleAmountIndex]
                .netCashChange
                .add(assetCash);
        }

        return settleAmounts;
    }

    /// @notice Stateful version of settle asset, the only difference is the call to getSettlementRateStateful
    function getSettleAssetContextStateful(PortfolioState memory portfolioState, uint256 blockTime)
        internal
        returns (SettleAmount[] memory)
    {
        AssetRateParameters memory settlementRate;
        SettleAmount[] memory settleAmounts = _getSettleAmountArray(portfolioState, blockTime);
        if (settleAmounts.length == 0) return settleAmounts;
        uint256 settleAmountIndex;
        uint256 lastMaturity;

        for (uint256 i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.getSettlementDate() > blockTime) continue;

            if (settleAmounts[settleAmountIndex].currencyId != asset.currencyId) {
                lastMaturity = 0;
                settleAmountIndex += 1;
                settleAmounts[settleAmountIndex].currencyId = asset.currencyId;
            }

            if (lastMaturity != asset.maturity && asset.maturity < blockTime) {
                // Storage Read / Write inside getSettlementRateStateful
                settlementRate = AssetRate.buildSettlementRateStateful(
                    asset.currencyId,
                    asset.maturity,
                    blockTime
                );
                lastMaturity = asset.maturity;
            }

            int256 assetCash;
            if (asset.assetType == Constants.FCASH_ASSET_TYPE) {
                assetCash = settlementRate.convertFromUnderlying(asset.notional);
                portfolioState.deleteAsset(i);
            } else if (AssetHandler.isLiquidityToken(asset.assetType)) {
                SettlementMarket memory market;
                if (asset.maturity > blockTime) {
                    (assetCash, market) = _settleLiquidityTokenTofCash(portfolioState, i);
                } else {
                    (assetCash, market) = _settleLiquidityToken(asset, settlementRate);
                    portfolioState.deleteAsset(i);
                }

                // 2x storage write
                Market.setSettlementMarket(market);
            }

            settleAmounts[settleAmountIndex].netCashChange = settleAmounts[settleAmountIndex]
                .netCashChange
                .add(assetCash);
        }

        return settleAmounts;
    }
}
