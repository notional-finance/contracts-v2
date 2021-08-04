// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

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
            uint256 // SettlementMarket memory // CERTORA: Returns the storage slot of the market
        )
    {
        // SettlementMarket memory market =
        //     Market.getSettlementMarket(asset.currencyId, asset.maturity, asset.getSettlementDate());
        
        bytes32 marketSlot = Market.getMarketSlot(asset.currencyId, asset.maturity, asset.getSettlementDate());
        Market.loadMarket(marketSlot);
        // Market.totalAssetCash(marketSlot); // replaces market.totalAssetCash
        // Market.totalfCash(marketSlot); // replaces market.totalfCash
        
        // int256 assetCash = market.totalAssetCash.mul(asset.notional).div(market.totalLiquidity);
        // int256 fCash = market.totalfCash.mul(asset.notional).div(market.totalLiquidity);

        int256 totalAssetCashStorage = Market.totalAssetCashStorage(marketSlot);
        int256 totalfCashStorage = Market.totalfCashStorage(marketSlot);
        int256 totalLiquidityStorage = Market.totalLiquidityStorage(marketSlot);

        int256 assetCash = totalAssetCashStorage.mul(asset.notional).div(totalLiquidityStorage);
        int256 fCash = totalfCashStorage.mul(asset.notional).div(totalLiquidityStorage);
        
        // market.totalfCash = market.totalfCash.subNoNeg(fCash);
        // market.totalAssetCash = market.totalAssetCash.subNoNeg(assetCash);
        // market.totalLiquidity = market.totalLiquidity.subNoNeg(asset.notional);

        Market.setTotalfCash(marketSlot, totalfCashStorage.subNoNeg(fCash));
        Market.setTotalAssetCash(marketSlot, totalAssetCashStorage.subNoNeg(assetCash));
        Market.setTotalLiquidity(marketSlot, totalLiquidityStorage.subNoNeg(asset.notional));

        return (assetCash, fCash, marketSlot);
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
        returns (int256, uint256) //SettlementMarket memory)
    {
        PortfolioAsset memory liquidityToken = portfolioState.storedAssets[index];
        (int256 assetCash, int256 fCash, uint256 marketSlot) = // SettlementMarket memory market) =
            _calculateMarketStorage(liquidityToken);

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
                // This fCash asset has not matured if were are settling to fCash
                fCashAsset.notional = fCashAsset.notional.add(fCash);
                fCashAsset.storageState = AssetStorageState.Update;

                portfolioState.deleteAsset(index);
                return (assetCash, marketSlot);
            }
        }

        liquidityToken.assetType = Constants.FCASH_ASSET_TYPE;
        liquidityToken.notional = fCash;
        liquidityToken.storageState = AssetStorageState.Update;

        return (assetCash, marketSlot);
    }

    /// @notice Settles a portfolio array
    function settlePortfolio(PortfolioState memory portfolioState, uint256 blockTime)
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
                // New currency in the portfolio
                lastMaturity = 0;
                settleAmountIndex += 1;
                settleAmounts[settleAmountIndex].currencyId = asset.currencyId;
            }

            // Saves a storage call if there is an fCash token and then an liquidity token after it
            if (lastMaturity != asset.maturity && asset.maturity < blockTime) {
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
                // SettlementMarket memory market;
                uint256 marketSlot;
                if (asset.maturity > blockTime) {
                    (assetCash, marketSlot) = _settleLiquidityTokenTofCash(portfolioState, i);
                } else {
                    (assetCash, market) = _settleLiquidityToken(asset, settlementRate);
                    portfolioState.deleteAsset(i);
                }

                Market.setMarket(marketSlot);
            }

            settleAmounts[settleAmountIndex].netCashChange = settleAmounts[settleAmountIndex]
                .netCashChange
                .add(assetCash);
        }

        return settleAmounts;
    }
}
