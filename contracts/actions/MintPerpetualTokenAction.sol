// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/PerpetualToken.sol";
import "../common/Market.sol";
import "../common/CashGroup.sol";
import "../common/AssetRate.sol";
import "../math/SafeInt256.sol";
import "../storage/BalanceHandler.sol";
import "../storage/AccountContextHandler.sol";
import "../storage/PortfolioHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library MintPerpetualTokenAction {
    using SafeInt256 for int256;
    using BalanceHandler for BalanceState;
    using AccountContextHandler for AccountStorage;
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;
    using PerpetualToken for PerpetualTokenPortfolio;
    using PortfolioHandler for PortfolioState;
    using AssetRate for AssetRateParameters;
    using SafeMath for uint;

    uint internal constant DELEVERAGE_BUFFER = 30000000; // 300 * Market.BASIS_POINT

    /**
     * @notice Converts the given amount of cash to perpetual tokens in the same currency. This method can
     * only be called by the contract itself.
     */
    function perpetualTokenMint(
        uint currencyId,
        int amountToDepositInternal
    ) external returns (int) {
        uint blockTime = block.timestamp;
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioStateful(currencyId);

        (int tokensToMint, bytes32 ifCashBitmap) = calculateTokensToMint(
            perpToken,
            amountToDepositInternal,
            blockTime
        );

        if (perpToken.portfolioState.storedAssets.length == 0) {
            // If the perp token does not have any assets, then the markets must be initialized first.
            perpToken.cashBalance = perpToken.cashBalance.add(amountToDepositInternal);
            BalanceHandler.setBalanceStorageForPerpToken(perpToken.tokenAddress, currencyId, perpToken.cashBalance);
        } else {
            depositIntoPortfolio(perpToken, ifCashBitmap, amountToDepositInternal, blockTime);
        }

        require(tokensToMint >= 0, "Invalid token amount");

        // NOTE: perpetual token supply does not change here, it will change after incentives have been
        // minted during BalanceHandler.finalize
        return tokensToMint;
    }

    /**
     * @notice Calculates the tokens to mint to the account as a ratio of the perpetual token
     * present value denominated in asset cash terms.
     */
    function calculateTokensToMint(
        PerpetualTokenPortfolio memory perpToken,
        int assetCashDeposit,
        uint blockTime
    ) internal view returns (int, bytes32) {
        require(assetCashDeposit >= 0); // dev: perpetual token deposit negative
        if (assetCashDeposit == 0) return (0, 0x0);

        if (perpToken.lastInitializedTime != 0) {
            // For the sake of simplicity, perpetual tokens cannot be minted if they have assets
            // that need to be settled. This is only done during market initialization.
            uint nextSettleTime = perpToken.getNextSettleTime();
            require(nextSettleTime > blockTime, "PT: requires settlement");
        }

        (int assetCashPV, bytes32 ifCashBitmap) = perpToken.getPerpetualTokenPV(blockTime);
        require(assetCashPV >= 0, "PT: pv value negative");

        // Allow for the first deposit
        if (perpToken.totalSupply == 0) return (assetCashDeposit, ifCashBitmap);

        return (
            assetCashDeposit.mul(perpToken.totalSupply).div(assetCashPV),
            ifCashBitmap
        );
    }

    /**
     * @notice Portions out assetCashDeposit into amounts to deposit into individual markets. When
     * entering this method we know that assetCashDeposit is positive and the perpToken has been
     * initialized to have liquidity tokens.
     */
    function depositIntoPortfolio(
        PerpetualTokenPortfolio memory perpToken,
        bytes32 ifCashBitmap,
        int assetCashDeposit,
        uint blockTime
    ) private {
        (int[] memory depositShares, int[] memory leverageThresholds) = PerpetualToken.getDepositParameters(
            perpToken.cashGroup.currencyId,
            perpToken.cashGroup.maxMarketIndex
        );

        // Loop backwards from the last market to the first market, the reasoning is a little complicated:
        // If we have to deleverage the markets (i.e. lend instead of provide liquidity) it's quite gas inefficient
        // to calculate the cash amount to lend. We do know that longer term maturities will have more
        // slippage and therefore the residual from the perMarketDeposit will be lower as the maturities get
        // closer to the current block time. Any residual cash from lending will be rolled into shorter
        // markets as this loop progresses.
        int residualCash;
        for (uint i = perpToken.markets.length - 1; i >= 0; i--) {
            int fCashAmount;
            MarketParameters memory market = perpToken.cashGroup.getMarket(
                perpToken.markets,
                i + 1, // Market index is 1-indexed
                blockTime,
                true // Needs liquidity to true
            );

            // We know from the call into this method that assetCashDeposit is positive
            int perMarketDeposit = assetCashDeposit
                .mul(depositShares[i])
                .div(PerpetualToken.DEPOSIT_PERCENT_BASIS)
                .add(residualCash);

            (fCashAmount, residualCash) = lendOrAddLiquidity(
                perpToken,
                market,
                perMarketDeposit,
                leverageThresholds[i],
                i,
                blockTime
            );

            if (fCashAmount != 0) {
                ifCashBitmap = BitmapAssetsHandler.setifCashAsset(
                    perpToken.tokenAddress,
                    perpToken.cashGroup.currencyId,
                    market.maturity,
                    perpToken.lastInitializedTime,
                    fCashAmount,
                    ifCashBitmap
                );
            }

            market.setMarketStorage();
            // Reached end of loop
            if (i == 0) break;
        }

        BitmapAssetsHandler.setAssetsBitmap(perpToken.tokenAddress, perpToken.cashGroup.currencyId, ifCashBitmap);
        perpToken.portfolioState.storeAssets(perpToken.tokenAddress);

        // This will occur if the three month market is over levered and we cannot lend into it
        if (residualCash != 0) {
            // Any remaining residual cash will be put into the perpetual token balance and added as liquidity on the
            // next market initialization
            perpToken.cashBalance = perpToken.cashBalance.add(residualCash);
            BalanceHandler.setBalanceStorageForPerpToken(perpToken.tokenAddress, perpToken.cashGroup.currencyId, perpToken.cashBalance);
        }
    }

    function lendOrAddLiquidity(
        PerpetualTokenPortfolio memory perpToken,
        MarketParameters memory market,
        int perMarketDeposit,
        int leverageThreshold,
        uint index,
        uint blockTime
    ) private returns (int, int) {
        int fCashAmount;
        bool marketOverLeveraged = isMarketOverLeveraged(perpToken.cashGroup, market, leverageThreshold);

        if (marketOverLeveraged) {
            (
                perMarketDeposit,
                fCashAmount
            ) = deleverageMarket(
                perpToken.cashGroup,
                market,
                perMarketDeposit,
                blockTime,
                index + 1
            );

            // Recalculate this after lending into the market
            marketOverLeveraged = isMarketOverLeveraged(perpToken.cashGroup, market, leverageThreshold);
        }

        if (!marketOverLeveraged) {
            fCashAmount = fCashAmount.add(addLiquidityToMarket(perpToken, market, index, perMarketDeposit));
            // No residual cash if we're adding liquidity
            return (fCashAmount, 0);
        }

        return (fCashAmount, perMarketDeposit);
    }

    function isMarketOverLeveraged(
        CashGroupParameters memory cashGroup,
        MarketParameters memory market,
        int leverageThreshold
    ) private pure returns (bool) {
        int totalCashUnderlying = cashGroup.assetRate.convertInternalToUnderlying(market.totalCurrentCash);
        int proportion = market.totalfCash
            .mul(Market.RATE_PRECISION)
            .div(market.totalfCash.add(totalCashUnderlying));

        // If proportion is over the threshold, the market is over leveraged
        return proportion > leverageThreshold;
    }

    function addLiquidityToMarket(
        PerpetualTokenPortfolio memory perpToken,
        MarketParameters memory market,
        uint index,
        int perMarketDeposit
    ) private pure returns (int) {
        // Add liquidity to the market
        PortfolioAsset memory asset = perpToken.portfolioState.storedAssets[index];
        // We expect that all the liquidity tokens are in the portfolio in order.
        require(
            asset.maturity == market.maturity
            // Ensures that the asset type references the proper liquidity token
            && asset.assetType == index + 2,
            "PT: invalid liquidity token"
        );

        // This will update the market state as well, fCashAmount returned here is negative
        (int liquidityTokens, int fCashAmount) = market.addLiquidity(perMarketDeposit);
        asset.notional = asset.notional.add(liquidityTokens);
        asset.storageState = AssetStorageState.Update;

        return fCashAmount;
    }

    /**
     * @notice Lends into the market to reduce the leverage that the perpetual token will add liquidity at. May fail due
     * to slippage or result in some amount of residual cash.
     */
    function deleverageMarket(
        CashGroupParameters memory cashGroup,
        MarketParameters memory market,
        int perMarketDeposit,
        uint blockTime,
        uint marketIndex
    ) private returns (int, int) {
        uint timeToMaturity = market.maturity.sub(blockTime);

        // Shift the last implied rate by some buffer and calculate the exchange rate to fCash. Hope that this
        // is sufficient to cover all potential slippage. We don't use the `getfCashGivenCashAmount` method here
        // because it is very gas inefficient.
        int assumedExchangeRate;
        if (market.lastImpliedRate < DELEVERAGE_BUFFER) {
            assumedExchangeRate = Market.RATE_PRECISION;
        } else {
            assumedExchangeRate = Market.getExchangeRateFromImpliedRate(
                market.lastImpliedRate.sub(DELEVERAGE_BUFFER),
                timeToMaturity
            );
        }

        int fCashAmount;
        {
            int perMarketDepositUnderlying = cashGroup.assetRate.convertInternalToUnderlying(perMarketDeposit);
            fCashAmount = perMarketDepositUnderlying.mul(assumedExchangeRate).div(Market.RATE_PRECISION);
        }
        (int netAssetCash, int fee) = market.calculateTrade(cashGroup, fCashAmount, timeToMaturity, marketIndex);
        BalanceHandler.incrementFeeToReserve(cashGroup.currencyId, fee);

        // This means that the trade failed
        if (netAssetCash == 0) return (perMarketDeposit, 0);

        // Ensure that net the per market deposit figure does not drop below zero, this should not be possible
        // given how we've calculated the exchange rate but extra caution here
        int residual = perMarketDeposit.add(netAssetCash);
        require(residual >= 0); // dev: insufficient cash
        return (residual, fCashAmount);
    }
}
