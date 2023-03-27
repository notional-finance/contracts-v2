// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {SettleAmount, AssetStorageState, PrimeRate} from "../../global/Types.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {Constants} from "../../global/Constants.sol";

import {PortfolioAsset, AssetHandler} from "../valuation/AssetHandler.sol";
import {Market, MarketParameters} from "../markets/Market.sol";
import {PortfolioState, PortfolioHandler} from "../portfolio/PortfolioHandler.sol";
import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";

library SettlePortfolioAssets {
    using SafeInt256 for int256;
    using PrimeRateLib for PrimeRate;
    using Market for MarketParameters;
    using PortfolioHandler for PortfolioState;
    using AssetHandler for PortfolioAsset;

    /// @dev Returns a SettleAmount array for the assets that will be settled
    function _getSettleAmountArray(
        PortfolioState memory portfolioState,
        uint256 blockTime
    ) private returns (SettleAmount[] memory) {
        uint256 currenciesSettled;
        uint16 lastCurrencyId = 0;
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
        if (currenciesSettled > 0) {
            settleAmounts[0].currencyId = lastCurrencyId;
            settleAmounts[0].presentPrimeRate = PrimeRateLib.buildPrimeRateStateful(lastCurrencyId);
        }

        return settleAmounts;
    }

    /// @notice Settles a portfolio array
    function settlePortfolio(
        address account,
        PortfolioState memory portfolioState,
        uint256 blockTime
    ) internal returns (SettleAmount[] memory) {
        SettleAmount[] memory settleAmounts = _getSettleAmountArray(portfolioState, blockTime);
        if (settleAmounts.length == 0) return settleAmounts;
        uint256 settleAmountIndex;

        for (uint256 i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            // Settlement date is on block time exactly
            if (asset.getSettlementDate() > blockTime) continue;

            // On the first loop the lastCurrencyId is already set.
            if (settleAmounts[settleAmountIndex].currencyId != asset.currencyId) {
                // New currency in the portfolio
                settleAmountIndex += 1;
                settleAmounts[settleAmountIndex].currencyId = asset.currencyId;
                settleAmounts[settleAmountIndex].presentPrimeRate =
                    PrimeRateLib.buildPrimeRateStateful(asset.currencyId);
            }
            SettleAmount memory sa = settleAmounts[settleAmountIndex];

            // Only the nToken is allowed to hold liquidity tokens
            require(asset.assetType == Constants.FCASH_ASSET_TYPE);
            // Gets or sets the settlement rate, only do this before settling fCash
            int256 primeCash = sa.presentPrimeRate.convertSettledfCash(
                account, asset.currencyId, asset.maturity, asset.notional, blockTime
            );
            portfolioState.deleteAsset(i);

            // Positive and negative settled cash are not net off in this method, they have to be
            // split up in order to properly update the total prime debt outstanding figure.
            if (primeCash > 0) {
                sa.positiveSettledCash = sa.positiveSettledCash.add(primeCash);
            } else {
                sa.negativeSettledCash = sa.negativeSettledCash.add(primeCash);
            }
        }

        return settleAmounts;
    }
}
