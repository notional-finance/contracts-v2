// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/Market.sol";
import "../common/CashGroup.sol";
import "../common/AssetRate.sol";
import "../common/PerpetualToken.sol";
import "../storage/BalanceHandler.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/SettleAssets.sol";
import "../math/SafeInt256.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * @notice Initialize markets is called once every quarter to setup the new markets. Only the perpetual
 * token account can initialize markets, and this method will be called on behalf of that account. In this action
 * the following will occur:
 *  - Perpetual Liquidity Tokens will be settled
 *  - Any ifCash assets will be settled
 *  - If perpetual liquidity tokens are settled with negative net ifCash, enough cash will be withheld at the PV
 *    to purchase offsetting positions
 *  - fCash positions are written to storage
 *  - For each market, starting at the new 6 month market, calculate the proportion of fCash to cash given:
 *     - previous oracle rates
 *     - rate anchor set by governance
 *     - percent of cash to deposit into the market set by governance
 *  - Set new markets and add liquidity tokens to portfolio
 */
library InitializeMarketsAction {
    using SafeMath for uint;
    using SafeInt256 for int;
    using PortfolioHandler for PortfolioState;
    using Market for MarketParameters;
    using BalanceHandler for BalanceState;
    using CashGroup for CashGroupParameters;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountStorage;

    event MarketsInitialized(uint16 currencyId);

    struct GovernanceParameters {
        int[] depositShares;
        int[] leverageThresholds;
        int[] rateAnchors;
        int[] proportions;
    }

    function getGovernanceParameters(
        uint currencyId,
        uint maxMarketIndex
    ) private view returns (GovernanceParameters memory) {
        GovernanceParameters memory params;
        (
            params.depositShares,
            params.leverageThresholds
        ) = PerpetualToken.getDepositParameters(currencyId, maxMarketIndex);

        (
            params.rateAnchors,
            params.proportions
        ) = PerpetualToken.getInitializationParameters(currencyId, maxMarketIndex);

        return params;
    }

    function settlePerpetualTokenPortfolio(
        PerpetualTokenPortfolio memory perpToken,
        uint blockTime
    ) private returns (bytes32) {
        // Perpetual token never has idiosyncratic cash between 90 day intervals but since it also has a
        // bitmapped cash group for fCash assets we don't set the pointer to the settlement date of the
        // liquidity tokens (1 quarter away), instead we set it to the current block time. This is a bit
        // esoteric but will ensure that ifCash is never improperly settled.
        uint referenceTime = CashGroup.getReferenceTime(blockTime);
        require(perpToken.lastInitializedTime < referenceTime, "IM: invalid time");

        {
            // Settles liquidity token balances and portfolio state now contains the net fCash amounts
            SettleAmount[] memory settleAmount = SettleAssets.getSettleAssetContextStateful(
                perpToken.portfolioState,
                blockTime
            );
            perpToken.cashBalance = perpToken.cashBalance.add(settleAmount[0].netCashChange);
        }

        (bytes32 ifCashBitmap, int settledAssetCash) = SettleAssets.settleBitmappedCashGroup(
            perpToken.tokenAddress,
            perpToken.cashGroup.currencyId,
            perpToken.lastInitializedTime,
            blockTime
        );
        perpToken.cashBalance = perpToken.cashBalance.add(settledAssetCash);

        // The ifCashBitmap has been updated to reference this new settlement time
        perpToken.lastInitializedTime = uint40(CashGroup.getTimeUTC0(blockTime));

        return ifCashBitmap;
    }

    /**
     * @notice Special method to get previous markets, normal usage would not reference previous markets
     * in this way
     */
    function getPreviousMarkets(
        uint currencyId,
        uint blockTime,
        PerpetualTokenPortfolio memory perpToken
    ) private view {
        uint rateOracleTimeWindow = perpToken.cashGroup.getRateOracleTimeWindow();
        // This will reference the previous settlement date to get the previous markets
        uint settlementDate = CashGroup.getReferenceTime(blockTime);

        // Assume that assets are stored in order and include all assets of the previous market
        // set. This will account for the potential that markets.length is greater than the previous
        // markets when the maxMarketIndex is increased (increasing the overall number of markets).
        // We don't fetch the 3 month market (i = 0) because it has settled and will not be used for
        // the subsequent calculations.
        for (uint i = 1; i < perpToken.portfolioState.storedAssets.length; i++) {
            perpToken.markets[i].loadMarketWithSettlementDate(
                currencyId,
                // These assets will reference the previous liquidity tokens
                perpToken.portfolioState.storedAssets[i].maturity,
                blockTime,
                // No liquidity tokens required for this process
                false,
                rateOracleTimeWindow,
                settlementDate
            );
        }
    }

    /**
     * @notice Check the net fCash assets set by the portfolio and withold cash to account for
     * the PV of negative ifCash. Also sets the ifCash assets into the perp token mapping.
     */
    function withholdAndSetfCashAssets(
        PerpetualTokenPortfolio memory perpToken,
        uint currencyId,
        bytes32 ifCashBitmap,
        uint blockTime,
        uint nextSettleTime
    ) private returns (int, bytes32) {
        // Residual fcash must be put into the ifCash bitmap from the portfolio, skip the 3 month
        // liquidity token since there is no residual fCash for that maturity, it always settles to cash.
        for (uint i = 1; i < perpToken.portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = perpToken.portfolioState.storedAssets[i];
            if (asset.assetType != AssetHandler.FCASH_ASSET_TYPE) continue;

            ifCashBitmap = BitmapAssetsHandler.setifCashAsset(
                perpToken.tokenAddress,
                currencyId,
                asset.maturity,
                nextSettleTime,
                asset.notional,
                ifCashBitmap
            );

            // Do not have fCash assets stored in the portfolio
            perpToken.portfolioState.deleteAsset(i);
        }

        // Recalculate what the witholdings are if there are any ifCash assets remaining
        int assetCashWitholding = BitmapAssetsHandler.getPerpetualTokenNegativefCashWitholding(
            perpToken.tokenAddress,
            currencyId,
            nextSettleTime,
            blockTime,
            ifCashBitmap,
            perpToken.cashGroup,
            perpToken.markets
        );

        return (assetCashWitholding, ifCashBitmap);
    }

    function calculateNetAssetCashAvailable(
        PerpetualTokenPortfolio memory perpToken,
        uint blockTime,
        uint currencyId,
        bool isFirstInit
    ) private returns (int, bytes32) {
        int netAssetCashAvailable;
        bytes32 ifCashBitmap;
        int assetCashWitholding;

        if (isFirstInit) {
            perpToken.lastInitializedTime = uint40(CashGroup.getTimeUTC0(blockTime));
        } else {
            ifCashBitmap = settlePerpetualTokenPortfolio(perpToken, blockTime);
            getPreviousMarkets(currencyId, blockTime, perpToken);
            (assetCashWitholding, ifCashBitmap) = withholdAndSetfCashAssets(
                perpToken,
                currencyId,
                ifCashBitmap,
                blockTime,
                perpToken.lastInitializedTime
            );
        }

        // We do not consider "storedCashBalance" because it may be holding cash that is used to
        // collateralize negative fCash from previous settlements except on the first initialization when
        // we know that there are no fCash assets at all
        netAssetCashAvailable = perpToken.cashBalance.subNoNeg(assetCashWitholding);

        // This is the new balance to store
        perpToken.cashBalance = perpToken.cashBalance.subNoNeg(netAssetCashAvailable);

        // We can't have less net asset cash than our percent basis or some markets will end up not
        // initialized
        require(
            netAssetCashAvailable > int(PerpetualToken.DEPOSIT_PERCENT_BASIS),
            "IM: insufficient cash"
        );

        return (netAssetCashAvailable, ifCashBitmap);
    }

    /**
     * @notice The six month implied rate is zero if there have never been any markets initialized
     * otherwise the market will be the interpolation between the old 6 month and 1 year markets
     * which are now sitting at 3 month and 9 month time to maturity
     */
    function getSixMonthImpliedRate(
        MarketParameters[] memory previousMarkets,
        uint referenceTime
    ) private pure returns (uint) {
        // Cannot interpolate six month rate without a 1 year market
        require (previousMarkets.length >= 3, "IM: six month error");

        return CashGroup.interpolateOracleRate(
            previousMarkets[1].maturity,
            previousMarkets[2].maturity,
            previousMarkets[1].oracleRate,
            previousMarkets[2].oracleRate,
            referenceTime + 2 * CashGroup.QUARTER
        );
    }

    /**
     * @notice Calculates a market proportion via the implied rate. The formula is:
     * exchangeRate = e ^ (impliedRate * timeToMaturity)
     * exchangeRate = (1 / rateScalar) * ln(proportion / (1 - proportion)) + rateAnchor
     *
     * proportion / (1 - proportion) = e^((exchangeRate - rateAnchor) * rateScalar)
     * exp = e^((exchangeRate - rateAnchor) * rateScalar)
     * proportion / (1 - proportion) = exp
     * exp * (1 - proportion) = proportion
     * exp - exp * proportion = proportion
     * exp = proportion + exp * proportion
     * exp = proportion * (1 + exp)
     * proportion = exp / (1 + exp)
     */
    function getProportionFromOracleRate(
        uint oracleRate,
        uint timeToMaturity,
        int rateScalar,
        int rateAnchor
    ) private pure returns (int) {
        int exchangeRate = Market.getExchangeRateFromImpliedRate(oracleRate, timeToMaturity);
        // If exchange rate is less than 1 then we set it to 1 so that this can continue
        if (exchangeRate < Market.RATE_PRECISION) {
            // TODO: Is this the correct thing to do?
            exchangeRate = Market.RATE_PRECISION;
        }

        int128 expValue = ABDKMath64x64.fromInt(exchangeRate.sub(rateAnchor).mul(rateScalar));
        // Scale this back to a decimal in abdk
        expValue = ABDKMath64x64.div(expValue, Market.RATE_PRECISION_64x64);
        // Take the exponent
        expValue = ABDKMath64x64.exp(expValue);
        // proportion = exp / (1 + exp)
        // NOTE: 2**64 == 1 in ABDKMath64x64
        int128 proportion = ABDKMath64x64.div(expValue, ABDKMath64x64.add(expValue, 2**64));

        // Scale this back to 1e9 precision
        proportion = ABDKMath64x64.mul(proportion, Market.RATE_PRECISION_64x64);

        return ABDKMath64x64.toInt(proportion);
    }

    /**
     * @notice Returns the linear interpolation between two market rates. The formula is
     * slope = (longMarket.oracleRate - shortMarket.oracleRate) / (longMarket.maturity - shortMarket.maturity)
     * interpolatedRate = slope * (assetMaturity - shortMarket.maturity) + shortMarket.oracleRate
     */
    function interpolateFutureRate(
        uint shortMaturity,
        uint shortRate,
        MarketParameters memory longMarket
    ) private pure returns (uint) {
        uint longMaturity = longMarket.maturity;
        uint longRate = longMarket.oracleRate;
        // the next market maturity is always a quarter away
        uint newMaturity = longMarket.maturity + CashGroup.QUARTER;
        require(shortMaturity < longMaturity, "IM: interpolation error");

        // It's possible that the rates are inverted where the short market rate > long market rate and
        // we will get underflows here so we check for that
        if (longRate >= shortRate) {
            return (longRate - shortRate)
                .mul(newMaturity - shortMaturity)
                // No underflow here, checked above
                .div(longMaturity - shortMaturity)
                .add(shortRate);
        } else {
            // In this case the slope is negative so:
            // interpolatedRate = shortMarket.oracleRate - slope * (assetMaturity - shortMarket.maturity)
            uint diff = (shortRate - longRate)
                .mul(newMaturity - shortMaturity)
                // No underflow here, checked above
                .div(longMaturity - shortMaturity);
            
            // This interpolation may go below zero so we bottom out interpolated rates at zero
            return shortRate > diff ? shortRate - diff : 0;
        }
    }

    function setLiquidityAmount(
        int netAssetCashAvailable,
        int depositShare,
        uint assetType,
        MarketParameters memory newMarket,
        PerpetualTokenPortfolio memory perpToken
    ) private pure returns (int) {
        // The portion of the cash available that will be deposited into the market
        int assetCashToMarket = netAssetCashAvailable
            .mul(depositShare)
            .div(PerpetualToken.DEPOSIT_PERCENT_BASIS);
        newMarket.totalCurrentCash = assetCashToMarket;
        newMarket.totalLiquidity = assetCashToMarket;

        // Add a new liquidity token, this will end up in the new asset array
        // TODO: skip this portfolio state method and just add the assets directly to the new assets list
        perpToken.portfolioState.addAsset(
            perpToken.cashGroup.currencyId,
            newMarket.maturity,
            assetType, // This is liquidity token asset type
            assetCashToMarket,
            true // Is new hint
        );

        // fCashAmount is calculated using the underlying amount
        return perpToken.cashGroup.assetRate.convertInternalToUnderlying(assetCashToMarket);
    }

    /**
     * @notice Initialize the market for a given currency id. An amount to deposit can be specified which
     * ensures that new markets will have some cash in them when we initialize.
     */
    function initializeMarkets(uint currencyId, bool isFirstInit) external {
        uint blockTime = block.timestamp;
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioStateful(currencyId);

        // This should be sufficient to validate that the currency id is valid
        require(perpToken.cashGroup.maxMarketIndex != 0, "IM: no markets to init");
        // If the perp token has any assets then this is not the first initialization
        if (isFirstInit) {
            require(perpToken.portfolioState.storedAssets.length == 0, "IM: not first init");
        }

        (int netAssetCashAvailable, bytes32 ifCashBitmap) = calculateNetAssetCashAvailable(
            perpToken,
            blockTime,
            currencyId,
            isFirstInit
        );

        GovernanceParameters memory parameters = getGovernanceParameters(
            currencyId,
            perpToken.cashGroup.maxMarketIndex
        );


        MarketParameters memory newMarket;
        // Oracle rate is carried over between loops
        uint oracleRate;
        for (uint i; i < perpToken.cashGroup.maxMarketIndex; i++) {
            // Traded markets are 1-indexed
            newMarket.maturity = CashGroup.getReferenceTime(blockTime).add(CashGroup.getTradedMarket(i + 1));

            int underlyingCashToMarket = setLiquidityAmount(
                netAssetCashAvailable,
                parameters.depositShares[i],
                2 + i, // liquidity token asset type
                newMarket,
                perpToken
            );

            uint timeToMaturity = newMarket.maturity.sub(blockTime);
            int rateScalar = perpToken.cashGroup.getRateScalar(i + 1, timeToMaturity);
            // Governance will prevent perpToken.markets.length from being equal to 1, meaning that we will
            // either have 0 markets (on first init), exactly 2 markets, or 2+ markets. In the case that there
            // are exactly two markets then the 6 month market must be initialized via this method (there is no
            // 9 month market to interpolate a rate against). In the case of 2+ markets then we will only enter this
            // first branch when the number of markets is increased
            if (isFirstInit ||
                // TODO: clean up this if statement
                (i == 1 && perpToken.markets.length == 2) ||
                // At this point, these are new markets and new markets must be created
                (i >= perpToken.portfolioState.storedAssets.length) ||
                // When extending from the 6 month to 1 year market we must initialize both 6 and 1 year as new
                (i == 1 && perpToken.markets[2].oracleRate == 0)
            ) {
                // Any newly added markets cannot have their implied rates interpolated via the previous
                // markets. In this case we initialize the markets using the rate anchor and proportion.
                // proportion = totalfCash / (totalfCash + totalCashUnderlying)
                // proportion * (totalfCash + totalCashUnderlying) = totalfCash
                // proportion * totalCashUnderlying + proportion * totalfCash = totalfCash
                // proportion * totalCashUnderlying = totalfCash * (1 - proportion)
                // totalfCash = proportion * totalCashUnderlying / (1 - proportion)
                int fCashAmount = underlyingCashToMarket
                    .mul(parameters.proportions[i])
                    .div(Market.RATE_PRECISION.sub(parameters.proportions[i]));

                newMarket.totalfCash = fCashAmount;
                newMarket.oracleRate = Market.getImpliedRate(
                    fCashAmount,
                    underlyingCashToMarket,
                    rateScalar,
                    int(parameters.rateAnchors[i]), // Will revert on out of bounds error here
                    timeToMaturity
                );

                // If this fails it is because the rate anchor and proportion are not set properly by
                // governance.
                require(newMarket.oracleRate > 0, "IM: implied rate failed");
            } else {
                // Two special cases for the 3 month and 6 month market when interpolating implied rates. The 3 month market
                // inherits the implied rate from the previous 6 month market (they are now at the same maturity).
                if (i == 0) {
                    // We should never get an array out of bounds error here because of the inequality check in the first branch
                    // of the outer if statement.
                    oracleRate = perpToken.markets[1].oracleRate;
                } else if (i == 1) {
                    // The six month market is the interpolation between the 3 month and the 1 year market (now at 9 months). This
                    // interpolation is different since the rate is between 3 and 9 months, for all the other interpolations we interpolate
                    // forward in time (i.e. use a 3 and 6 month rate to interpolate a 1 year rate). The first branch of this if statement
                    // will capture the case when the 1 year rate has not been set.
                    oracleRate = getSixMonthImpliedRate(
                        perpToken.markets,
                        CashGroup.getReferenceTime(blockTime)
                    );
                } else {
                    // Any other market has the interpolation between the new implied rate from the newly initialized market previous
                    // to this market interpolated with the previous version of this market. For example, the newly initialized 1 year
                    // market will have its implied rate set to the interpolation between the newly initialized 6 month market (done in
                    // previous iteration of this loop) and the previous 1 year market (which has now rolled down to 9 months). Similarly,
                    // a 2 year market will be interpolated from the newly initialized 1 year and the previous 2 year market.
                    
                    // This is the previous market maturity, traded markets are 1-indexed
                    uint shortMarketMaturity = CashGroup.getReferenceTime(blockTime).add(CashGroup.getTradedMarket(i));
                    oracleRate = interpolateFutureRate(
                        shortMarketMaturity,
                        oracleRate,
                        perpToken.markets[i]
                    );
                }

                // When initializing new markets we need to ensure that the new implied oracle rates align
                // with the current yield curve or valuations for ifCash will spike. This should reference the
                // previously calculated implied rate and the current market.
                int proportion = getProportionFromOracleRate(
                    oracleRate,
                    timeToMaturity,
                    rateScalar,
                    parameters.rateAnchors[i]
                );

                // If the calculated proportion is greater than the leverage threshold then we cannot
                // provide liquidity without risk of liquidation. In this case, set the leverage threshold
                // as the new proportion and calculate the oracle rate from it. This will result in fCash valuations
                // changing on chain, however, adding liquidity via perpetual tokens would also end up with this
                // result as well.
                if (proportion > parameters.leverageThresholds[i]) {
                    proportion = parameters.leverageThresholds[i];
                    newMarket.totalfCash = underlyingCashToMarket
                        .mul(proportion)
                        .div(Market.RATE_PRECISION.sub(proportion));

                    oracleRate = Market.getImpliedRate(
                        newMarket.totalfCash,
                        underlyingCashToMarket,
                        rateScalar,
                        parameters.rateAnchors[i],
                        timeToMaturity
                    );

                    require(oracleRate != 0, "Oracle rate overflow");
                } else {
                    newMarket.totalfCash = underlyingCashToMarket
                        .mul(proportion)
                        .div(Market.RATE_PRECISION.sub(proportion));
                }

                // It's possible for proportion to be equal to zero, in this case we set the totalfCash to a minimum
                // value so that we don't have divide by zero errors.
                if (proportion == 0) newMarket.totalfCash = 1;

                newMarket.oracleRate = oracleRate;
                // Inherit the previous trade time from the last market
                newMarket.previousTradeTime = blockTime;
            }

            newMarket.lastImpliedRate = newMarket.oracleRate;
            ifCashBitmap = finalizeMarket(newMarket, currencyId, perpToken.tokenAddress, ifCashBitmap);
        }

        (
            /* hasDebt */,
            /* activeCurrencies */,
            uint8 assetArrayLength,
            /* nextSettleTime */
        ) = perpToken.portfolioState.storeAssets(perpToken.tokenAddress);
        BalanceHandler.setBalanceStorageForPerpToken(perpToken);
        BitmapAssetsHandler.setAssetsBitmap(perpToken.tokenAddress, currencyId, ifCashBitmap);
        PerpetualToken.setArrayLengthAndInitializedTime(
            perpToken.tokenAddress,
            assetArrayLength,
            perpToken.lastInitializedTime
        );

        emit MarketsInitialized(uint16(currencyId));
    }

    function finalizeMarket(
        MarketParameters memory market,
        uint currencyId,
        address tokenAddress,
        bytes32 ifCashBitmap
    ) internal returns (bytes32) {
        uint blockTime = block.timestamp;
        // Always reference the current settlement date
        uint settlementDate = CashGroup.getReferenceTime(blockTime) + CashGroup.QUARTER;
        market.storageSlot = Market.getSlot(currencyId, settlementDate, market.maturity);
        market.storageState = Market.STORAGE_STATE_INITIALIZE_MARKET;
        market.setMarketStorage();

        return BitmapAssetsHandler.setifCashAsset(
            tokenAddress,
            currencyId,
            market.maturity,
            CashGroup.getTimeUTC0(blockTime),
            market.totalfCash.neg(),
            ifCashBitmap
        );
    }
}