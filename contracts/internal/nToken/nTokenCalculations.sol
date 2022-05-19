// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./nTokenHandler.sol";
import "../portfolio/BitmapAssetsHandler.sol";
import "../../math/SafeInt256.sol";
import "../../math/Bitmap.sol";

library nTokenCalculations {
    using Bitmap for bytes32;
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;
    using CashGroup for CashGroupParameters;

    /// @notice Returns the nToken present value denominated in asset terms.
    function getNTokenAssetPV(nTokenPortfolio memory nToken, uint256 blockTime)
        internal
        view
        returns (int256)
    {
        {
            uint256 nextSettleTime = nTokenHandler.getNextSettleTime(nToken);
            // If the first asset maturity has passed (the 3 month), this means that all the LTs must
            // be settled except the 6 month (which is now the 3 month). We don't settle LTs except in
            // initialize markets so we calculate the cash value of the portfolio here.
            if (nextSettleTime <= blockTime) {
                // NOTE: this condition should only be present for a very short amount of time, which is the window between
                // when the markets are no longer tradable at quarter end and when the new markets have been initialized.
                // We time travel back to one second before maturity to value the liquidity tokens. Although this value is
                // not strictly correct the different should be quite slight. We do this to ensure that free collateral checks
                // for withdraws and liquidations can still be processed. If this condition persists for a long period of time then
                // the entire protocol will have serious problems as markets will not be tradable.
                blockTime = nextSettleTime - 1;
            }
        }

        // This is the total value in liquid assets
        (int256 totalAssetValueInMarkets, /* int256[] memory netfCash */) = getNTokenMarketValue(nToken, blockTime);

        // Then get the total value in any idiosyncratic fCash residuals (if they exist)
        bytes32 ifCashBits = getNTokenifCashBits(
            nToken.tokenAddress,
            nToken.cashGroup.currencyId,
            nToken.lastInitializedTime,
            blockTime,
            nToken.cashGroup.maxMarketIndex
        );

        int256 ifCashResidualUnderlyingPV = 0;
        if (ifCashBits != 0) {
            // Non idiosyncratic residuals have already been accounted for
            (ifCashResidualUnderlyingPV, /* hasDebt */) = BitmapAssetsHandler.getNetPresentValueFromBitmap(
                nToken.tokenAddress,
                nToken.cashGroup.currencyId,
                nToken.lastInitializedTime,
                blockTime,
                nToken.cashGroup,
                false, // nToken present value calculation does not use risk adjusted values
                ifCashBits
            );
        }

        // Return the total present value denominated in asset terms
        return totalAssetValueInMarkets
            .add(nToken.cashGroup.assetRate.convertFromUnderlying(ifCashResidualUnderlyingPV))
            .add(nToken.cashBalance);
    }

    /**
     * @notice Handles the case when liquidity tokens should be withdrawn in proportion to their amounts
     * in the market. This will be the case when there is no idiosyncratic fCash residuals in the nToken
     * portfolio.
     * @param nToken portfolio object for nToken
     * @param nTokensToRedeem amount of nTokens to redeem
     * @param tokensToWithdraw array of liquidity tokens to withdraw from each market, proportional to
     * the account's share of the total supply
     * @param netfCash an empty array to hold net fCash values calculated later when the tokens are actually
     * withdrawn from markets
     */
    function _getProportionalLiquidityTokens(
        nTokenPortfolio memory nToken,
        int256 nTokensToRedeem
    ) private pure returns (int256[] memory tokensToWithdraw, int256[] memory netfCash) {
        uint256 numMarkets = nToken.portfolioState.storedAssets.length;
        tokensToWithdraw = new int256[](numMarkets);
        netfCash = new int256[](numMarkets);

        for (uint256 i = 0; i < numMarkets; i++) {
            int256 totalTokens = nToken.portfolioState.storedAssets[i].notional;
            tokensToWithdraw[i] = totalTokens.mul(nTokensToRedeem).div(nToken.totalSupply);
        }
    }

    /**
     * @notice Returns the number of liquidity tokens to withdraw from each market if the nToken
     * has idiosyncratic residuals during nToken redeem. In this case the redeemer will take
     * their cash from the rest of the fCash markets, redeeming around the nToken.
     * @param nToken portfolio object for nToken
     * @param nTokensToRedeem amount of nTokens to redeem
     * @param blockTime block time
     * @param ifCashBits the bits in the bitmap that represent ifCash assets
     * @return tokensToWithdraw array of tokens to withdraw from each corresponding market
     * @return netfCash array of netfCash amounts to go back to the account
     */
    function getLiquidityTokenWithdraw(
        nTokenPortfolio memory nToken,
        int256 nTokensToRedeem,
        uint256 blockTime,
        bytes32 ifCashBits
    ) internal view returns (int256[] memory, int256[] memory) {
        // If there are no ifCash bits set then this will just return the proportion of all liquidity tokens
        if (ifCashBits == 0) return _getProportionalLiquidityTokens(nToken, nTokensToRedeem);

        (
            int256 totalAssetValueInMarkets,
            int256[] memory netfCash
        ) = getNTokenMarketValue(nToken, blockTime);
        int256[] memory tokensToWithdraw = new int256[](netfCash.length);

        // NOTE: this total portfolio asset value does not include any cash balance the nToken may hold.
        // The redeemer will always get a proportional share of this cash balance and therefore we don't
        // need to account for it here when we calculate the share of liquidity tokens to withdraw. We are
        // only concerned with the nToken's portfolio assets in this method.
        int256 totalPortfolioAssetValue;
        {
            // Returns the risk adjusted net present value for the idiosyncratic residuals
            (int256 underlyingPV, /* hasDebt */) = BitmapAssetsHandler.getNetPresentValueFromBitmap(
                nToken.tokenAddress,
                nToken.cashGroup.currencyId,
                nToken.lastInitializedTime,
                blockTime,
                nToken.cashGroup,
                true, // use risk adjusted here to assess a penalty for withdrawing around the residual
                ifCashBits
            );

            // NOTE: we do not include cash balance here because the account will always take their share
            // of the cash balance regardless of the residuals
            totalPortfolioAssetValue = totalAssetValueInMarkets.add(
                nToken.cashGroup.assetRate.convertFromUnderlying(underlyingPV)
            );
        }

        // Loops through each liquidity token and calculates how much the redeemer can withdraw to get
        // the requisite amount of present value after adjusting for the ifCash residual value that is
        // not accessible via redemption.
        for (uint256 i = 0; i < tokensToWithdraw.length; i++) {
            int256 totalTokens = nToken.portfolioState.storedAssets[i].notional;
            // Redeemer's baseline share of the liquidity tokens based on total supply:
            //      redeemerShare = totalTokens * nTokensToRedeem / totalSupply
            // Scalar factor to account for residual value (need to inflate the tokens to withdraw
            // proportional to the value locked up in ifCash residuals):
            //      scaleFactor = totalPortfolioAssetValue / totalAssetValueInMarkets
            // Final math equals:
            //      tokensToWithdraw = redeemerShare * scalarFactor
            //      tokensToWithdraw = (totalTokens * nTokensToRedeem * totalPortfolioAssetValue)
            //         / (totalAssetValueInMarkets * totalSupply)
            tokensToWithdraw[i] = totalTokens
                .mul(nTokensToRedeem)
                .mul(totalPortfolioAssetValue);

            tokensToWithdraw[i] = tokensToWithdraw[i]
                .div(totalAssetValueInMarkets)
                .div(nToken.totalSupply);

            // This is the share of net fcash that will be credited back to the account
            netfCash[i] = netfCash[i].mul(tokensToWithdraw[i]).div(totalTokens);
        }

        return (tokensToWithdraw, netfCash);
    }

    /// @notice Returns the value of all the liquid assets in an nToken portfolio which are defined by
    /// the liquidity tokens held in each market and their corresponding fCash positions. The formula
    /// can be described as:
    /// totalAssetValue = sum_per_liquidity_token(cashClaim + presentValue(netfCash))
    ///     where netfCash = fCashClaim + fCash
    ///     and fCash refers the the fCash position at the corresponding maturity
    function getNTokenMarketValue(nTokenPortfolio memory nToken, uint256 blockTime)
        internal
        view
        returns (int256 totalAssetValue, int256[] memory netfCash)
    {
        uint256 numMarkets = nToken.portfolioState.storedAssets.length;
        netfCash = new int256[](numMarkets);

        MarketParameters memory market;
        for (uint256 i = 0; i < numMarkets; i++) {
            // Load the corresponding market into memory
            nToken.cashGroup.loadMarket(market, i + 1, true, blockTime);
            PortfolioAsset memory liquidityToken = nToken.portfolioState.storedAssets[i];
            uint256 maturity = liquidityToken.maturity;

            // Get the fCash claims and fCash assets. We do not use haircut versions here because
            // nTokenRedeem does not require it and getNTokenPV does not use it (a haircut is applied
            // at the end of the calculation to the entire PV instead).
            (int256 assetCashClaim, int256 fCashClaim) = AssetHandler.getCashClaims(liquidityToken, market);

            // fCash is denominated in underlying
            netfCash[i] = fCashClaim.add(
                BitmapAssetsHandler.getifCashNotional(
                    nToken.tokenAddress,
                    nToken.cashGroup.currencyId,
                    maturity
                )
            );

            // This calculates for a single liquidity token:
            // assetCashClaim + convertToAssetCash(pv(netfCash))
            int256 netAssetValueInMarket = assetCashClaim.add(
                nToken.cashGroup.assetRate.convertFromUnderlying(
                    AssetHandler.getPresentfCashValue(
                        netfCash[i],
                        maturity,
                        blockTime,
                        // No need to call cash group for oracle rate, it is up to date here
                        // and we are assured to be referring to this market.
                        market.oracleRate
                    )
                )
            );

            // Calculate the running total
            totalAssetValue = totalAssetValue.add(netAssetValueInMarket);
        }
    }

    /// @notice Returns just the bits in a bitmap that are idiosyncratic
    function getNTokenifCashBits(
        address tokenAddress,
        uint256 currencyId,
        uint256 lastInitializedTime,
        uint256 blockTime,
        uint256 maxMarketIndex
    ) internal view returns (bytes32) {
        // If max market index is less than or equal to 2, there are never ifCash assets by construction
        if (maxMarketIndex <= 2) return bytes32(0);
        bytes32 assetsBitmap = BitmapAssetsHandler.getAssetsBitmap(tokenAddress, currencyId);
        // Handles the case when there are no assets at the first initialization
        if (assetsBitmap == 0) return assetsBitmap;

        uint256 tRef = DateTime.getReferenceTime(blockTime);

        if (tRef == lastInitializedTime) {
            // This is a more efficient way to turn off ifCash assets in the common case when the market is
            // initialized immediately
            return assetsBitmap & ~(Constants.ACTIVE_MARKETS_MASK);
        } else {
            // In this branch, initialize markets has occurred past the time above. It would occur in these
            // two scenarios (both should be exceedingly rare):
            // 1. initializing a cash group with 3+ markets for the first time (not beginning on the tRef)
            // 2. somehow initialize markets has been delayed for more than 24 hours
            for (uint i = 1; i <= maxMarketIndex; i++) {
                // In this loop we get the maturity of each active market and turn off the corresponding bit
                // one by one. It is less efficient than the option above.
                uint256 maturity = tRef + DateTime.getTradedMarket(i);
                (uint256 bitNum, /* */) = DateTime.getBitNumFromMaturity(lastInitializedTime, maturity);
                assetsBitmap = assetsBitmap.setBit(bitNum, false);
            }

            return assetsBitmap;
        }
    }
}