// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./AssetRate.sol";
import "./CashGroup.sol";
import "./DateTime.sol";
import "../../global/Types.sol";
import "../../global/Constants.sol";
import "../../math/SafeInt256.sol";
import "../../math/ABDKMath64x64.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library Market {
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using CashGroup for CashGroupParameters;
    using AssetRate for AssetRateParameters;

    bytes1 private constant STORAGE_STATE_NO_CHANGE = 0x00;
    
    
    
    bytes1 private constant STORAGE_STATE_UPDATE_LIQUIDITY = 0x01;
    bytes1 private constant STORAGE_STATE_UPDATE_TRADE = 0x02;
    bytes1 internal constant STORAGE_STATE_INITIALIZE_MARKET = 0x03; // Both settings are set

    // Max positive value for a ABDK64x64 integer
    int256 private constant MAX64 = 0x7FFFFFFFFFFFFFFF;

    /// @notice Add liquidity to a market, assuming that it is initialized. If not then
    /// this method will revert and the market must be initialized first.
    /// @return liquidityTokenAmount and net negative fCash
    function addLiquidity(MarketParameters storage market, int256 assetCash)
        internal
        returns (int256, int256)
    {
        require(market.totalLiquidity > 0, "M: zero liquidity");
        if (assetCash == 0) return (0, 0);
        require(assetCash > 0); // dev: negative asset cash

        int256 liquidityTokens = market.totalLiquidity.mul(assetCash).div(market.totalAssetCash);
        // No need to convert this to underlying, assetCash / totalAssetCash is a unitless proportion.
        int256 fCash = market.totalfCash.mul(assetCash).div(market.totalAssetCash);

        market.totalLiquidity = market.totalLiquidity.add(liquidityTokens);
        market.totalfCash = market.totalfCash.add(fCash);
        market.totalAssetCash = market.totalAssetCash.add(assetCash);
        market.storageState = updateLiquidity(market.storageState);
        // market.storageState = market.storageState | STORAGE_STATE_UPDATE_LIQUIDITY;

        return (liquidityTokens, fCash.neg());
    }

    /// @notice Remove liquidity from a market, assuming that it is initialized.
    /// @return asset cash and positive fCash claim to return
    function removeLiquidity(MarketParameters storage market, int256 tokensToRemove)
        internal
        returns (int256, int256)
    {
        if (tokensToRemove == 0) return (0, 0);
        require(tokensToRemove > 0); // dev: negative tokens to remove

        int256 assetCash = market.totalAssetCash.mul(tokensToRemove).div(market.totalLiquidity);
        int256 fCash = market.totalfCash.mul(tokensToRemove).div(market.totalLiquidity);

        market.totalLiquidity = market.totalLiquidity.subNoNeg(tokensToRemove);
        market.totalfCash = market.totalfCash.subNoNeg(fCash);
        market.totalAssetCash = market.totalAssetCash.subNoNeg(assetCash);
        market.storageState = updateLiquidity(market.storageState);
        // market.storageState = market.storageState | STORAGE_STATE_UPDATE_LIQUIDITY;

        return (assetCash, fCash);
    }

    /// @notice Calculates the asset cash amount the results from trading fCashToAccount with the market. A positive
    /// fCashToAccount is equivalent of lending, a negative is borrowing. Updates the market state in memory.
    /// @param market the current market state
    /// @param cashGroup cash group configuration parameters
    /// @param fCashToAccount the fCash amount that will be deposited into the user's portfolio. The net change
    /// to the market is in the opposite direction.
    /// @param timeToMaturity number of seconds until maturity
    /// @return netAssetCash, netAssetCashToReserve
    function calculateTrade(
        MarketParameters storage market,
        CashGroupParameters storage cashGroup,
        int256 fCashToAccount,
        uint256 timeToMaturity,
        uint256 marketIndex
    ) internal returns (int256, int256) {
        // We return false if there is not enough fCash to support this trade.
        if (market.totalfCash.sub(fCashToAccount) <= 0) return (0, 0);

        (int256 rateScalar, int256 totalCashUnderlying, int256 rateAnchor) =
            getExchangeRateFactors(market, cashGroup, timeToMaturity, marketIndex);

        int256 preFeeExchangeRate;
        {
            bool success;
            (preFeeExchangeRate, success) = _getExchangeRate(
                market.totalfCash,
                totalCashUnderlying,
                rateScalar,
                rateAnchor,
                fCashToAccount
            );
            if (!success) return (0, 0);
        }

        (int256 netCashToAccount, int256 netCashToMarket, int256 netCashToReserve) =
            _getNetCashAmountsUnderlying(
                cashGroup,
                preFeeExchangeRate,
                fCashToAccount,
                timeToMaturity
            );
        if (netCashToAccount == 0) return (0, 0);

        {
            market.totalfCash = market.totalfCash.subNoNeg(fCashToAccount);
            market.lastImpliedRate = getImpliedRate(
                market.totalfCash,
                totalCashUnderlying.add(netCashToMarket),
                rateScalar,
                rateAnchor,
                timeToMaturity
            );

            // It's technically possible that the implied rate is actually exactly zero (or
            // more accurately the natural log rounds down to zero) but we will still fail
            // in this case. If this does happen we may assume that markets are not initialized.
            if (market.lastImpliedRate == 0) return (0, 0);
        }

        return
            _setNewMarketState(
                market,
                cashGroup.assetRate,
                netCashToAccount,
                netCashToMarket,
                netCashToReserve
            );
    }

    /// @notice Returns factors for calculating exchange rates
    function getExchangeRateFactors(
        MarketParameters storage market,
        CashGroupParameters memory cashGroup,
        uint256 timeToMaturity,
        uint256 marketIndex
    )
        internal
        view
        returns (
            int256,
            int256,
            int256
        )
    {
        int256 rateScalar = cashGroup.getRateScalar(marketIndex, timeToMaturity);
        int256 totalCashUnderlying = cashGroup.assetRate.convertToUnderlying(market.totalAssetCash);

        // This will result in a divide by zero
        if (market.totalfCash == 0 || totalCashUnderlying == 0) return (0, 0, 0);

        // Get the rate anchor given the market state, this will establish the baseline for where
        // the exchange rate is set.
        int256 rateAnchor;
        {
            bool success;
            (rateAnchor, success) = _getRateAnchor(
                market.totalfCash,
                market.lastImpliedRate,
                totalCashUnderlying,
                rateScalar,
                timeToMaturity
            );
            if (!success) return (0, 0, 0);
        }

        return (rateScalar, totalCashUnderlying, rateAnchor);
    }

    /// @dev Returns net asset cash amounts to the account, the market and the reserve
    function _getNetCashAmountsUnderlying(
        CashGroupParameters memory cashGroup,
        int256 preFeeExchangeRate,
        int256 fCashToAccount,
        uint256 timeToMaturity
    )
        private
        pure
        returns (
            int256,
            int256,
            int256
        )
    {
        // Fees are specified in basis points which is an implied rate denomination. We convert this to
        // an exchange rate denomination for the given time to maturity. (i.e. get e^(fee * t) and multiply
        // or divide depending on the side of the trade).
        // tradeExchangeRate = exp((tradeInterestRateNoFee +/- fee) * timeToMaturity)
        // tradeExchangeRate = tradeExchangeRateNoFee (* or /) exp(fee * timeToMaturity)
        int256 preFeeCashToAccount =
            fCashToAccount.mul(Constants.RATE_PRECISION).div(preFeeExchangeRate).neg();
        int256 fee = getExchangeRateFromImpliedRate(cashGroup.getTotalFee(), timeToMaturity);

        if (fCashToAccount > 0) {
            // Lending
            int256 postFeeExchangeRate = preFeeExchangeRate.mul(Constants.RATE_PRECISION).div(fee);
            // It's possible that the fee pushes exchange rates into negative territory. This is not possible
            // when borrowing. If this happens then the trade has failed.
            if (postFeeExchangeRate < Constants.RATE_PRECISION) return (0, 0, 0);

            // cashToAccount = -(fCashToAccount / exchangeRate)
            // postFeeExchangeRate = preFeeExchangeRate / feeExchangeRate
            // preFeeCashToAccount = -(fCashToAccount / preFeeExchangeRate)
            // postFeeCashToAccount = -(fCashToAccount / postFeeExchangeRate)
            // netFee = preFeeCashToAccount - postFeeCashToAccount
            // netFee = (fCashToAccount / postFeeExchangeRate) - (fCashToAccount / preFeeExchangeRate)
            // netFee = ((fCashToAccount * feeExchangeRate) / preFeeExchangeRate) - (fCashToAccount / preFeeExchangeRate)
            // netFee = (fCashToAccount / preFeeExchangeRate) * (feeExchangeRate - 1)
            // netFee = -(preFeeCashToAccount) * (feeExchangeRate - 1)
            // netFee = preFeeCashToAccount * (1 - feeExchangeRate)
            fee = preFeeCashToAccount.mul(Constants.RATE_PRECISION.sub(fee)).div(
                Constants.RATE_PRECISION
            );
        } else {
            // Borrowing
            // cashToAccount = -(fCashToAccount / exchangeRate)
            // postFeeExchangeRate = preFeeExchangeRate * feeExchangeRate

            // netFee = preFeeCashToAccount - postFeeCashToAccount
            // netFee = (fCashToAccount / postFeeExchangeRate) - (fCashToAccount / preFeeExchangeRate)
            // netFee = ((fCashToAccount / (feeExchangeRate * preFeeExchangeRate)) - (fCashToAccount / preFeeExchangeRate)
            // netFee = (fCashToAccount / preFeeExchangeRate) * (1 / feeExchangeRate - 1)
            // netFee = preFeeCashToAccount * ((1 - feeExchangeRate) / feeExchangeRate)
            // NOTE: preFeeCashToAccount is negative in this branch so we negate it to ensure that fee is a positive number
            fee = preFeeCashToAccount.mul(Constants.RATE_PRECISION.sub(fee)).div(fee).neg();
        }

        int256 cashToReserve =
            fee.mul(cashGroup.getReserveFeeShare()).div(Constants.PERCENTAGE_DECIMALS);

        return (
            // postFeeCashToAccount = preFeeCashToAccount - fee
            preFeeCashToAccount.sub(fee),
            // netCashToMarket = -(preFeeCashToAccount - fee + cashToReserve)
            (preFeeCashToAccount.sub(fee).add(cashToReserve)).neg(),
            cashToReserve
        );
    }

    function _setNewMarketState(
        MarketParameters storage market,
        AssetRateParameters memory assetRate,
        int256 netCashToAccount,
        int256 netCashToMarket,
        int256 netCashToReserve
    ) private returns (int256, int256) {
        int256 netAssetCashToMarket = assetRate.convertFromUnderlying(netCashToMarket);
        market.totalAssetCash = market.totalAssetCash.add(netAssetCashToMarket);

        // Sets the trade time for the next oracle update
        market.previousTradeTime = block.timestamp;
        market.storageState = updateTrade(market.storageState);
        // market.storageState = market.storageState | STORAGE_STATE_UPDATE_TRADE;

        int256 assetCashToReserve = assetRate.convertFromUnderlying(netCashToReserve);
        int256 netAssetCashToAccount = assetRate.convertFromUnderlying(netCashToAccount);
        return (netAssetCashToAccount, assetCashToReserve);
    }

    /// @notice Rate anchors update as the market gets closer to maturity. Rate anchors are not comparable
    /// across time or markets but implied rates are. The goal here is to ensure that the implied rate
    /// before and after the rate anchor update is the same. Therefore, the market will trade at the same implied
    /// rate that it last traded at. If these anchors do not update then it opens up the opportunity for arbitrage
    /// which will hurt the liquidity providers.
    ///
    /// The rate anchor will update as the market rolls down to maturity. The calculation is:
    /// newExchangeRate = e^(lastImpliedRate * timeToMaturity / Constants.IMPLIED_RATE_TIME)
    /// newAnchor = newExchangeRate - ln((proportion / (1 - proportion)) / rateScalar
    ///
    /// where:
    /// lastImpliedRate = ln(exchangeRate') * (Constants.IMPLIED_RATE_TIME / timeToMaturity')
    ///      (calculated when the last trade in the market was made)
    /// @dev has an underscore to denote as private but is marked internal for the mock
    /// @return the new rate anchor and a boolean that signifies success
    function _getRateAnchor(
        int256 totalfCash,
        uint256 lastImpliedRate,
        int256 totalCashUnderlying,
        int256 rateScalar,
        uint256 timeToMaturity
    ) internal pure returns (int256, bool) {
        // This is the exchange rate at the new time to maturity
        int256 exchangeRate = getExchangeRateFromImpliedRate(lastImpliedRate, timeToMaturity);
        if (exchangeRate < Constants.RATE_PRECISION) return (0, false);

        int256 rateAnchor;
        {
            int256 proportion =
                totalfCash.mul(Constants.RATE_PRECISION).div(totalfCash.add(totalCashUnderlying));

            (int256 lnProportion, bool success) = _logProportion(proportion);
            if (!success) return (0, false);

            rateAnchor = exchangeRate.sub(lnProportion.div(rateScalar));
        }

        return (rateAnchor, true);
    }

    /// @notice Calculates the current market implied rate.
    /// @return the implied rate and a bool that is true on success
    function getImpliedRate(
        int256 totalfCash,
        int256 totalCashUnderlying,
        int256 rateScalar,
        int256 rateAnchor,
        uint256 timeToMaturity
    ) internal pure returns (uint256) {
        // This will check for exchange rates < Constants.RATE_PRECISION
        (int256 exchangeRate, bool success) =
            _getExchangeRate(totalfCash, totalCashUnderlying, rateScalar, rateAnchor, 0);
        if (!success) return 0;

        // Uses continuous compounding to calculate the implied rate:
        // ln(exchangeRate) * Constants.IMPLIED_RATE_TIME / timeToMaturity
        int128 rate = ABDKMath64x64.fromInt(exchangeRate);
        int128 rateScaled = ABDKMath64x64.div(rate, Constants.RATE_PRECISION_64x64);
        // We will not have a negative log here because we check that exchangeRate > Constants.RATE_PRECISION
        // inside getExchangeRate
        int128 lnRateScaled = ABDKMath64x64.ln(rateScaled);
        uint256 lnRate =
            ABDKMath64x64.toUInt(ABDKMath64x64.mul(lnRateScaled, Constants.RATE_PRECISION_64x64));

        uint256 impliedRate = lnRate.mul(Constants.IMPLIED_RATE_TIME).div(timeToMaturity);

        // Implied rates over 429% will overflow, this seems like a safe assumption
        if (impliedRate > type(uint32).max) return 0;

        return impliedRate;
    }

    /// @notice Converts an implied rate to an exchange rate given a time to maturity. The
    /// formula is E = e^rt
    function getExchangeRateFromImpliedRate(uint256 impliedRate, uint256 timeToMaturity)
        internal
        pure
        returns (int256)
    {
        int128 expValue =
            ABDKMath64x64.fromUInt(
                impliedRate.mul(timeToMaturity).div(Constants.IMPLIED_RATE_TIME)
            );
        int128 expValueScaled = ABDKMath64x64.div(expValue, Constants.RATE_PRECISION_64x64);
        int128 expResult = ABDKMath64x64.exp(expValueScaled);
        int128 expResultScaled = ABDKMath64x64.mul(expResult, Constants.RATE_PRECISION_64x64);

        return ABDKMath64x64.toInt(expResultScaled);
    }

    /// @notice Returns the exchange rate between fCash and cash for the given market
    /// Calculates the following exchange rate:
    ///     (1 / rateScalar) * ln(proportion / (1 - proportion)) + rateAnchor
    /// where:
    ///     proportion = totalfCash / (totalfCash + totalUnderlyingCash)
    /// @dev has an underscore to denote as private but is marked internal for the mock
    function _getExchangeRate(
        int256 totalfCash,
        int256 totalCashUnderlying,
        int256 rateScalar,
        int256 rateAnchor,
        int256 fCashToAccount
    ) internal pure returns (int256, bool) {
        int256 numerator = totalfCash.subNoNeg(fCashToAccount);

        // This is the proportion scaled by Constants.RATE_PRECISION
        int256 proportion =
            numerator.mul(Constants.RATE_PRECISION).div(totalfCash.add(totalCashUnderlying));

        (int256 lnProportion, bool success) = _logProportion(proportion);
        if (!success) return (0, false);

        // Division will not overflow here because we know rateScalar > 0
        int256 rate = (lnProportion / rateScalar).add(rateAnchor);
        // Do not succeed if interest rates fall below 1
        if (rate < Constants.RATE_PRECISION) {
            return (0, false);
        } else {
            return (rate, true);
        }
    }

    /// @dev This method calculates the log of the proportion inside the logit function which is
    /// defined as ln(proportion / (1 - proportion)). Special handling here is required to deal with
    /// fixed point precision and the ABDK library.
    /*function _logProportion(int256 proportion) internal pure returns (int256, bool) {
        if (proportion == Constants.RATE_PRECISION) return (0, false);

        proportion = proportion.mul(Constants.RATE_PRECISION).div(
            Constants.RATE_PRECISION.sub(proportion)
        );

        // This is the max 64 bit integer for ABDKMath. This is unlikely to trip because the
        // value is 9.2e18 and the proportion is scaled by 1e9. We can hit very high levels of
        // pool utilization before this returns false.
        if (proportion > MAX64) return (0, false);

        // ABDK does not handle log of numbers that are less than 1, in order to get the right value
        // scaled by RATE_PRECISION we use the log identity:
        // (ln(proportion / RATE_PRECISION)) * RATE_PRECISION = (ln(proportion) - ln(RATE_PRECISION)) * RATE_PRECISION
        int128 abdkProportion = ABDKMath64x64.fromInt(proportion);
        // Here, abdk will revert due to negative log so abort
        if (abdkProportion <= 0) return (0, false);
        int256 result =
            ABDKMath64x64.toInt(
                ABDKMath64x64.mul(
                    ABDKMath64x64.sub(
                        ABDKMath64x64.ln(abdkProportion),
                        Constants.LOG_RATE_PRECISION_64x64
                    ),
                    Constants.RATE_PRECISION_64x64
                )
            );

        return (result, true);
    } */

    //gadi
    function _logProportion(int256 x) internal pure returns (int256, bool) {
    if (x <= 0 || x >= Constants.RATE_PRECISION)
        return (0,false);
    if (x > 19*Constants.RATE_PRECISION/20)
        return(1000 * x - 950 * Constants.RATE_PRECISION,true);
    if (x < Constants.RATE_PRECISION/20)
        return(1000 * x - 50 * Constants.RATE_PRECISION,true);
    // between 0.05 and 0.95
    return(6 * x - 3 * Constants.RATE_PRECISION,true);
    }
    // even more simplified
    // function _logProportion(int256 x) internal pure returns (int256, bool) {
    // return (x,true);
    // }

    /// @notice Oracle rate protects against short term price manipulation. Time window will be set to a value
    /// on the order of minutes to hours. This is to protect fCash valuations from market manipulation. For example,
    /// a trader could use a flash loan to dump a large amount of cash into the market and depress interest rates.
    /// Since we value fCash in portfolios based on these rates, portfolio values will decrease and they may then
    /// be liquidated.
    ///
    /// Oracle rates are calculated when the market is loaded from storage.
    ///
    /// The oracle rate is a lagged weighted average over a short term price window. If we are past
    /// the short term window then we just set the rate to the lastImpliedRate, otherwise we take the
    /// weighted average:
    ///     lastImpliedRatePreTrade * (currentTs - previousTs) / timeWindow +
    ///         oracleRatePrevious * (1 - (currentTs - previousTs) / timeWindow)
    function _updateRateOracle(
        uint256 previousTradeTime,
        uint256 lastImpliedRate,
        uint256 oracleRate,
        uint256 rateOracleTimeWindow,
        uint256 blockTime
    ) private pure returns (uint256) {
        require(rateOracleTimeWindow > 0); // dev: update rate oracle, time window zero

        // This can occur when using a view function get to a market state in the past
        if (previousTradeTime > blockTime) return lastImpliedRate;

        uint256 timeDiff = blockTime.sub(previousTradeTime);
        if (timeDiff > rateOracleTimeWindow) {
            // If past the time window just return the lastImpliedRate
            return lastImpliedRate;
        }

        // (currentTs - previousTs) / timeWindow
        uint256 lastTradeWeight =
            timeDiff.mul(uint256(Constants.RATE_PRECISION)).div(rateOracleTimeWindow);

        // 1 - (currentTs - previousTs) / timeWindow
        uint256 oracleWeight = uint256(Constants.RATE_PRECISION).sub(lastTradeWeight);

        uint256 newOracleRate =
            (lastImpliedRate.mul(lastTradeWeight).add(oracleRate.mul(oracleWeight))).div(
                uint256(Constants.RATE_PRECISION)
            );

        return newOracleRate;
    }

    // function getSlot(
    //     uint256 currencyId,
    //     uint256 settlementDate,
    //     uint256 maturity
    // ) internal pure returns (bytes32) {
    //     return
    //         keccak256(
    //             abi.encode(
    //                 maturity,
    //                 keccak256(
    //                     abi.encode(
    //                         settlementDate,
    //                         keccak256(abi.encode(currencyId, Constants.MARKET_STORAGE_OFFSET))
    //                     )
    //                 )
    //             )
    //         );
    // }

    /// @notice Liquidity is not required for lending and borrowing so we don't automatically read it. This method is called if we
    /// do need to load the liquidity amount.
    function getTotalLiquidity(MarketParameters storage market) internal {
        // int256 totalLiquidity;
        // bytes32 slot = bytes32(uint256(market.storageSlot) + 1);

        // assembly {
        //     totalLiquidity := sload(slot)
        // }
        market.totalLiquidity = market.totalLiquidityStorage;
    }

    function getOracleRate(
        uint256 currencyId,
        uint256 maturity,
        uint256 rateOracleTimeWindow,
        uint256 blockTime
    ) internal view returns (uint256) {
        uint256 settlementDate = DateTime.getReferenceTime(blockTime) + Constants.QUARTER;
        bytes32 marketSlot = getMarketSlot(currencyId, maturity, settlementDate);
        
        uint256 lastImpliedRate = lastImpliedRateStorage(marketSlot);
        uint256 oracleRate = oracleRateStorage(marketSlot);
        uint256 previousTradeTime = previousTradeTimeStorage(marketSlot);
        
        // uint256 settlementDate = DateTime.getReferenceTime(blockTime) + Constants.QUARTER;
        // bytes32 slot = getSlot(currencyId, settlementDate, maturity);
        // bytes32 data;

        // assembly {
        //     data := sload(slot)
        // }

        // uint256 lastImpliedRate = uint256(uint32(uint256(data >> 160)));
        // uint256 oracleRate = uint256(uint32(uint256(data >> 192)));
        // uint256 previousTradeTime = uint256(uint32(uint256(data >> 224)));

        // // If the oracle rate is set to zero this can only be because the markets have past their settlement
        // // date but the new set of markets has not yet been initialized. This means that accounts cannot be liquidated
        // // during this time, but market initialization can be called by anyone so the actual time that this condition
        // // exists for should be quite short.
        require(oracleRate > 0, "Market not initialized");

        return
            _updateRateOracle(
                previousTradeTime,
                lastImpliedRate,
                oracleRate,
                rateOracleTimeWindow,
                blockTime
            );
    }

    /// @notice Reads a market object directly from storage. `buildMarket` should be called instead of this method
    /// which ensures that the rate oracle is set properly.
    function _loadMarketStorage(
        MarketParameters storage market,
        uint256 currencyId,
        uint256 maturity,
        bool needsLiquidity,
        uint256 settlementDate
    ) private {
        // Market object always uses the most current reference time as the settlement date
        // bytes32 slot = getSlot(currencyId, settlementDate, maturity);
        // bytes32 data;

        // assembly {
        //     data := sload(slot)
        // }

        // market.storageSlot = slot;

        market.maturity = maturity;
        
        // CERTORA: Copy "storage" values into corresponding "memory" ones
        market.totalfCash = market.totalfCashStorage; // int256(uint80(uint256(data)));
        market.totalAssetCash = market.totalAssetCashStorage; // int256(uint80(uint256(data >> 80)));
        market.lastImpliedRate = market.lastImpliedRateStorage;  // uint256(uint32(uint256(data >> 160)));
        market.oracleRate =  market.oracleRateStorage; // uint256(uint32(uint256(data >> 192)));
        market.previousTradeTime = market.previousTradeTimeStorage; // uint256(uint32(uint256(data >> 224)));
        // market.storageState = STORAGE_STATE_NO_CHANGE;

        if (needsLiquidity) {
            getTotalLiquidity(market);
        } else {
            market.totalLiquidity = 0;
        }
    }

    // /// @notice Writes market parameters to storage if the market is marked as updated.
    // function setMarketStorage(MarketParameters memory market) internal {
    //     if (market.storageState == STORAGE_STATE_NO_CHANGE) return;
    //     bytes32 slot = market.storageSlot;

    //     if (market.storageState & STORAGE_STATE_UPDATE_TRADE != STORAGE_STATE_UPDATE_TRADE) {
    //         // If no trade has occurred then the oracleRate on chain should not update.
    //         bytes32 oldData;
    //         assembly {
    //             oldData := sload(slot)
    //         }
    //         market.oracleRate = uint256(uint32(uint256(oldData >> 192)));
    //     }

    //     require(market.totalfCash >= 0 && market.totalfCash <= type(uint80).max); // dev: market storage totalfCash overflow
    //     require(market.totalAssetCash >= 0 && market.totalAssetCash <= type(uint80).max); // dev: market storage totalAssetCash overflow
    //     require(market.lastImpliedRate >= 0 && market.lastImpliedRate <= type(uint32).max); // dev: market storage lastImpliedRate overflow
    //     require(market.oracleRate >= 0 && market.oracleRate <= type(uint32).max); // dev: market storage oracleRate overflow
    //     require(market.previousTradeTime >= 0 && market.previousTradeTime <= type(uint32).max); // dev: market storage previous trade time overflow

    //     bytes32 data =
    //         (bytes32(market.totalfCash) |
    //             (bytes32(market.totalAssetCash) << 80) |
    //             (bytes32(market.lastImpliedRate) << 160) |
    //             (bytes32(market.oracleRate) << 192) |
    //             (bytes32(market.previousTradeTime) << 224));

    //     assembly {
    //         sstore(slot, data)
    //     }

    //     if (
    //         market.storageState & STORAGE_STATE_UPDATE_LIQUIDITY == STORAGE_STATE_UPDATE_LIQUIDITY
    //     ) {
    //         require(market.totalLiquidity >= 0 && market.totalLiquidity <= type(uint80).max); // dev: market storage totalLiquidity overflow
    //         slot = bytes32(uint256(slot) + 1);
    //         bytes32 totalLiquidity = bytes32(market.totalLiquidity);

    //         assembly {
    //             sstore(slot, totalLiquidity)
    //         }
    //     }
    // }

     /// @notice Writes market parameters to storage if the market is marked as updated.
    function setMarketStorage(MarketParameters storage market) internal {
        // if (market.storageState == STORAGE_STATE_NO_CHANGE) return;
        // bytes32 slot = market.storageSlot;

        // if (market.storageState & STORAGE_STATE_UPDATE_TRADE != STORAGE_STATE_UPDATE_TRADE) 
        // if (!getTrade(market.storageState))
        {
            // If no trade has occurred then the oracleRate on chain should not update.
            // bytes32 oldData;
            // assembly {
            //     oldData := sload(slot)
            // }
            // market.oracleRate = uint256(uint32(uint256(oldData >> 192)));
            market.oracleRate = market.oracleRateStorage;
        }

        require(market.totalfCash >= 0 && market.totalfCash <= type(uint80).max); // dev: market storage totalfCash overflow
        require(market.totalAssetCash >= 0 && market.totalAssetCash <= type(uint80).max); // dev: market storage totalAssetCash overflow
        require(market.lastImpliedRate >= 0 && market.lastImpliedRate <= type(uint32).max); // dev: market storage lastImpliedRate overflow
        require(market.oracleRate >= 0 && market.oracleRate <= type(uint32).max); // dev: market storage oracleRate overflow
        require(market.previousTradeTime >= 0 && market.previousTradeTime <= type(uint32).max); // dev: market storage previous trade time overflow

        // only updating the "storage" fields that have a "memory" counterpart whose value may be different in some cases than the one in "storage"
        market.totalfCashStorage = market.totalfCash;
        market.totalAssetCashStorage = market.totalAssetCash;
        market.lastImpliedRateStorage = market.lastImpliedRate;
        market.oracleRateStorage = market.oracleRate;
        market.previousTradeTimeStorage = market.previousTradeTime;
        
        // bytes32 data =
        //     (bytes32(market.totalfCash) |
        //         (bytes32(market.totalAssetCash) << 80) |
        //         (bytes32(market.lastImpliedRate) << 160) |
        //         (bytes32(market.oracleRate) << 192) |
        //         (bytes32(market.previousTradeTime) << 224));

        // assembly {
        //     sstore(slot, data)
        // }

        if (
            // market.storageState & STORAGE_STATE_UPDATE_LIQUIDITY == STORAGE_STATE_UPDATE_LIQUIDITY // Waiting for Or's fix
            // getLiquidity(market.storageState)
            true
        ) {
            require(market.totalLiquidity >= 0 && market.totalLiquidity <= type(uint80).max); // dev: market storage totalLiquidity overflow
            // slot = bytes32(uint256(slot) + 1);
            // bytes32 totalLiquidity = bytes32(market.totalLiquidity);
    
            // assembly {
            //     sstore(slot, totalLiquidity)
            // }
            market.totalLiquidityStorage = market.totalLiquidity;
        }
    }


    /// @notice Creates a market object and ensures that the rate oracle time window is updated appropriately.
    function loadMarket(
        // mapping(uint256 => mapping(uint256 => mapping(uint256 => MarketParameters))) storage symbolicMarkets,
        MarketParameters storage market,
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime,
        bool needsLiquidity,
        uint256 rateOracleTimeWindow
    ) internal returns(uint256 settlementDate) {
        // Always reference the current settlement date
        settlementDate = DateTime.getReferenceTime(blockTime) + Constants.QUARTER;
        loadMarketWithSettlementDate(
            market,
            currencyId,
            maturity,
            blockTime,
            needsLiquidity,
            rateOracleTimeWindow,
            settlementDate
        );
    }

    /// @notice Creates a market object and ensures that the rate oracle time window is updated appropriately, this
    /// is mainly used in the InitializeMarketAction contract.
    function loadMarketWithSettlementDate(
        // mapping(uint256 => mapping(uint256=>mapping(uint256 => MarketParameters))) storage symbolicMarkets,
        MarketParameters storage market, 
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime,
        bool needsLiquidity,
        uint256 rateOracleTimeWindow,
        uint256 settlementDate
    ) internal {
        // MarketParameters storage market = symbolicMarkets[currencyId][settlementDate][maturity];
        _loadMarketStorage(market, currencyId, maturity, needsLiquidity, settlementDate);
        market.oracleRate = _updateRateOracle(
            market.previousTradeTime,
            market.lastImpliedRate,
            market.oracleRate,
            rateOracleTimeWindow,
            blockTime
        );
    }
    function getMarketSlot(
        uint256 currencyId, // 1
        uint256 maturity, // 3
        uint256 settlementDate  // 2
        ) internal view returns(bytes32) {
        //     bytes32 slot;
		//     assembly {
		// 	    mstore(0, currencyId)
		// 	    mstore(32, 0)
		// 	    slot := keccak256(0, 64)
		//     }
        //     assembly {
		// 	    mstore(0, settlementDate)
		// 	    mstore(32, slot)
		// 	    slot := keccak256(0, 64)
		//     }
        //     assembly {
		// 	    mstore(0, maturity)
		// 	    mstore(32, slot)
		// 	    slot := keccak256(0, 64)
		//     }
		//   return slot;
        return bytes32(uint(6));
    }

    // CERTORA: Replaces getSettlementMarket 
    function loadMarket(bytes32 marketSlot) internal {
        setTotalfCash(marketSlot, totalfCashStorage(marketSlot));
        setTotalAssetCash(marketSlot, totalAssetCashStorage(marketSlot));
        setTotalLiquidity(marketSlot, totalLiquidityStorage(marketSlot));
        setLastImpliedRate(marketSlot, lastImpliedRateStorage(marketSlot));
        setOracleRate(marketSlot, oracleRateStorage(marketSlot));
        setPreviousTradeTime(marketSlot, previousTradeTimeStorage(marketSlot));
    }

    /// @notice When settling liquidity tokens we only need to get half of the market parameters and the settlement
    /// date must be specified.
    // Remove this function. Replace with functions in the harness. Set functions and get functions of primitive members in struct.
    // function getSettlementMarket(
    //     uint256 currencyId,
    //     uint256 maturity,
    //     uint256 settlementDate
    // ) internal view returns (SettlementMarket storage) {
    //     MarketParameters storage market = symbolicMarkets[currencyId][settlementDate][maturity];
    //     return market;
        
    //     // market.totalfCash = market.totalfCashStorage;


        

    //     // return symbolicMarkets[currencyId][settlementDate][maturity];
        
    //     // uint256 slot = uint256(getSlot(currencyId, settlementDate, maturity));
    //     // int256 totalLiquidity;
    //     // bytes32 data;

    //     // assembly {
    //     //     data := sload(slot)
    //     // }

    //     // int256 totalfCash = int256(uint80(uint256(data)));
    //     // int256 totalAssetCash = int256(uint80(uint256(data >> 80)));
    //     // // Clear the lower 160 bits, this data will be combined with the new totalfCash
    //     // // and totalAssetCash figures.
    //     // data = data & 0xffffffffffffffffffffffff0000000000000000000000000000000000000000;

    //     // slot = uint256(slot) + 1;

    //     // assembly {
    //     //     totalLiquidity := sload(slot)
    //     // }

    //     // return
    //     //     SettlementMarket({
    //     //         storageSlot: bytes32(slot - 1),
    //     //         totalfCash: totalfCash,
    //     //         totalAssetCash: totalAssetCash,
    //     //         totalLiquidity: int256(totalLiquidity),
    //     //         data: data
    //     //     });
    // }

    // function setSettlementMarket(SettlementMarket memory market) internal {
    //     bytes32 slot = market.storageSlot;
    //     bytes32 data;
    //     require(market.totalfCash >= 0 && market.totalfCash <= type(uint80).max); // dev: settlement market storage totalfCash overflow
    //     require(market.totalAssetCash >= 0 && market.totalAssetCash <= type(uint80).max); // dev: settlement market storage totalAssetCash overflow
    //     require(market.totalLiquidity >= 0 && market.totalLiquidity <= type(uint80).max); // dev: settlement market storage totalLiquidity overflow

    //     data = (bytes32(market.totalfCash) |
    //         (bytes32(market.totalAssetCash) << 80) |
    //         bytes32(market.data));

    //     // Don't clear the storage even when all liquidity tokens have been removed because we need to use
    //     // the oracle rates to initialize the next set of markets.
    //     assembly {
    //         sstore(slot, data)
    //     }

    //     slot = bytes32(uint256(slot) + 1);
    //     bytes32 totalLiquidity = bytes32(market.totalLiquidity);
    //     assembly {
    //         sstore(slot, totalLiquidity)
    //     }
    // }

     function setMarket(bytes32 marketSlot) internal {
        setTotalfCashStorage(marketSlot, totalfCash(marketSlot));
        setTotalAssetCashStorage(marketSlot, totalAssetCash(marketSlot));
        setTotalLiquidityStorage(marketSlot, totalLiquidity(marketSlot));
        setLastImpliedRateStorage(marketSlot, lastImpliedRate(marketSlot));
        setOracleRateStorage(marketSlot, oracleRate(marketSlot));
        setPreviousTradeTimeStorage(marketSlot, previousTradeTime(marketSlot));
    }

     function sloadFromMarketSlotPlusK(bytes32 marketSlot, uint256 k) private view returns(bytes32) {
        bytes32 slot = bytes32(uint256(marketSlot) + k);
        bytes32 slotData;
        assembly {
            slotData := sload(slot)
        }
        return slotData;
     }

    function sstoreAtMarketSlotPlusK(bytes32 marketSlot, uint256 k, bytes32 slotData) private {
        bytes32 slot = bytes32(uint256(marketSlot) + k);
        assembly {
            sstore(slot, slotData)
        }
    }

    ////////////////////////////////// Getters ///////////////////////////////////////////////
    function totalfCash(bytes32 marketSlot) internal view returns (int256) { // 0 
        return int256(sloadFromMarketSlotPlusK(marketSlot, 0));
     }
    function totalAssetCash(bytes32 marketSlot) internal view returns (int256) { // 1 
        return int256(sloadFromMarketSlotPlusK(marketSlot, 1));
    }
    function totalLiquidity(bytes32 marketSlot) internal view returns (int256) { // 2 
        return int256(sloadFromMarketSlotPlusK(marketSlot, 2));
    }
    
    function lastImpliedRate(bytes32 marketSlot) internal view returns (uint256) { // 3 
        return uint256(sloadFromMarketSlotPlusK(marketSlot, 3));
    }
    function oracleRate(bytes32 marketSlot) internal view returns (uint256) { // 4 
        return uint256(sloadFromMarketSlotPlusK(marketSlot, 4));
    }
    function previousTradeTime(bytes32 marketSlot) internal view returns (uint256) { // 5 
        return uint256(sloadFromMarketSlotPlusK(marketSlot, 5));
    }
    function storageState(bytes32 marketSlot) internal view returns (bytes1) { // 6 
        return bytes1(sloadFromMarketSlotPlusK(marketSlot, 6));
    }
    function maturity(bytes32 marketSlot) internal view returns (uint256) { // 7 
        return uint256(sloadFromMarketSlotPlusK(marketSlot, 7));
    }
    
    function totalfCashStorage(bytes32 marketSlot) internal view returns (int256) { // 8 
        return int256(sloadFromMarketSlotPlusK(marketSlot, 8));
    }
    
    function totalAssetCashStorage(bytes32 marketSlot) internal view returns (int256) { // 9 
        return int256(sloadFromMarketSlotPlusK(marketSlot, 9));
    }

    function totalLiquidityStorage(bytes32 marketSlot) internal view returns (int256) { // 10 
        return int256(sloadFromMarketSlotPlusK(marketSlot, 10));
    }
    function lastImpliedRateStorage(bytes32 marketSlot) internal view returns (uint256) { // 11 
        return uint256(sloadFromMarketSlotPlusK(marketSlot, 11));
    }
    function oracleRateStorage(bytes32 marketSlot) internal view returns (uint256) { // 12
        return uint256(sloadFromMarketSlotPlusK(marketSlot, 12));
    }
    function previousTradeTimeStorage(bytes32 marketSlot) internal view returns (uint256) { // 13
        return uint256(sloadFromMarketSlotPlusK(marketSlot, 13));
    }
    
    ////////////////////////////// Setters ///////////////////////////////////////////////////
    function setTotalfCash(bytes32 marketSlot, int256 value) internal { // 0 
        sstoreAtMarketSlotPlusK(marketSlot, 0, bytes32(value));
     }
     
    function setTotalAssetCash(bytes32 marketSlot, int256 value) internal { // 1 
        sstoreAtMarketSlotPlusK(marketSlot, 1, bytes32(value));
     }

    function setTotalLiquidity(bytes32 marketSlot, int256 value) internal  { // 2 
       sstoreAtMarketSlotPlusK(marketSlot, 2, bytes32(value));
    }

    function setLastImpliedRate(bytes32 marketSlot, uint256 value) internal  { // 3 
       sstoreAtMarketSlotPlusK(marketSlot, 3, bytes32(value));
    }

    function setOracleRate(bytes32 marketSlot, uint256 value) internal  { // 4 
       sstoreAtMarketSlotPlusK(marketSlot, 4, bytes32(value));
    }

    function setPreviousTradeTime(bytes32 marketSlot, uint256 value) internal  { // 5
       sstoreAtMarketSlotPlusK(marketSlot, 5, bytes32(value));
    }

    function setStorageState(bytes32 marketSlot, bytes1 value) internal  { // 6 
       sstoreAtMarketSlotPlusK(marketSlot, 6, bytes32(value));
    }
    function setMaturity(bytes32 marketSlot, uint256 value) internal  { // 7 
       sstoreAtMarketSlotPlusK(marketSlot, 7, bytes32(value));
    }

    function setTotalfCashStorage(bytes32 marketSlot, int256 value) internal  { // 8 // ask Or
        require(value >= 0 && value <= type(uint80).max);
        sstoreAtMarketSlotPlusK(marketSlot, 8, bytes32(value));
    }
    
    function setTotalAssetCashStorage(bytes32 marketSlot, int256 value) internal  { // 9
        require(value >= 0 && value <= type(uint80).max); 
        sstoreAtMarketSlotPlusK(marketSlot, 9, bytes32(value));
    }
    
    function setTotalLiquidityStorage(bytes32 marketSlot, int256 value) internal { // 10 
       require(value >= 0 && value <= type(uint80).max);
       sstoreAtMarketSlotPlusK(marketSlot, 10, bytes32(value));
    }

    function setLastImpliedRateStorage(bytes32 marketSlot, uint256 value) internal { // 11 
       sstoreAtMarketSlotPlusK(marketSlot, 11, bytes32(value));
    }
    
    function setOracleRateStorage(bytes32 marketSlot, uint256 value) internal { // 12 
       sstoreAtMarketSlotPlusK(marketSlot, 12, bytes32(value));
    }
    function setPreviousTradeTimeStorage(bytes32 marketSlot, uint256 value) internal { // 13 
       sstoreAtMarketSlotPlusK(marketSlot, 13, bytes32(value));
    }

    /// Uses Newton's method to converge on an fCash amount given the amount of
    /// cash. The relation between cash and fcash is:
    /// cashAmount * exchangeRate * fee + fCash = 0
    /// where exchangeRate(fCash) = (rateScalar ^ -1) * ln(p / (1 - p)) + rateAnchor
    ///       p = (totalfCash - fCash) / (totalfCash + totalCash)
    ///       if cashAmount < 0: fee = feeRate ^ -1
    ///       if cashAmount > 0: fee = feeRate
    ///
    /// Newton's method is:
    /// fCash_(n+1) = fCash_n - f(fCash) / f'(fCash)
    ///
    /// f(fCash) = cashAmount * exchangeRate(fCash) * fee + fCash
    ///
    ///                                    (totalfCash + totalCash)
    /// exchangeRate'(fCash) = -  ------------------------------------------
    ///                           (totalfCash - fCash) * (totalCash + fCash)
    ///
    /// https://www.wolframalpha.com/input/?i=ln%28%28%28a-x%29%2F%28a%2Bb%29%29%2F%281-%28a-x%29%2F%28a%2Bb%29%29%29
    ///
    ///                     (cashAmount * fee) * (totalfCash + totalCash)
    /// f'(fCash) = 1 - ------------------------------------------------------
    ///                 rateScalar * (totalfCash - fCash) * (totalCash + fCash)
    ///
    /// NOTE: each iteration costs about 11.3k so this is only done via a view function.
    function getfCashGivenCashAmount(// discuss with Noam
        int256 totalfCash,
        int256 netCashToAccount,
        int256 totalCashUnderlying,
        int256 rateScalar,
        int256 rateAnchor,
        int256 feeRate,
        uint256 maxDelta
    ) internal pure returns (int256) {
        int256 fCashChangeToAccountGuess =
            netCashToAccount.mul(rateAnchor).div(Constants.RATE_PRECISION).neg();
        for (uint8 i; i < 250; i++) {
            (int256 exchangeRate, bool success) =
                _getExchangeRate(
                    totalfCash,
                    totalCashUnderlying,
                    rateScalar,
                    rateAnchor,
                    fCashChangeToAccountGuess
                );

            require(success); // dev: invalid exchange rate
            int256 delta =
                _calculateDelta(
                    netCashToAccount,
                    totalfCash,
                    totalCashUnderlying,
                    rateScalar,
                    fCashChangeToAccountGuess,
                    exchangeRate,
                    feeRate
                );

            if (delta.abs() <= int256(maxDelta)) return fCashChangeToAccountGuess;
            fCashChangeToAccountGuess = fCashChangeToAccountGuess.sub(delta);
        }

        revert("No convergence");
    }

    /// @dev Calculates: f(fCash) / f'(fCash)
    /// f(fCash) = cashAmount * exchangeRate * fee + fCash
    ///                     (cashAmount * fee) * (totalfCash + totalCash)
    /// f'(fCash) = 1 - ------------------------------------------------------
    ///                 rateScalar * (totalfCash - fCash) * (totalCash + fCash)
    function _calculateDelta(
        int256 cashAmount,
        int256 totalfCash,
        int256 totalCashUnderlying,
        int256 rateScalar,
        int256 fCashGuess,
        int256 exchangeRate,
        int256 feeRate
    ) private pure returns (int256) {
        int256 derivative;
        // rateScalar * (totalfCash - fCash) * (totalCash + fCash)
        // Precision: TOKEN_PRECISION ^ 2
        int256 denominator =
            rateScalar.mul(totalfCash.sub(fCashGuess)).mul(totalCashUnderlying.add(fCashGuess));

        if (fCashGuess > 0) {
            // Lending
            exchangeRate = exchangeRate.mul(Constants.RATE_PRECISION).div(feeRate);
            require(exchangeRate >= Constants.RATE_PRECISION); // dev: rate underflow

            // (cashAmount / fee) * (totalfCash + totalCash)
            // Precision: TOKEN_PRECISION ^ 2
            derivative = cashAmount
                .mul(Constants.RATE_PRECISION)
                .mul(totalfCash.add(totalCashUnderlying))
                .div(feeRate);
        } else {
            // Borrowing
            exchangeRate = exchangeRate.mul(feeRate).div(Constants.RATE_PRECISION);
            require(exchangeRate >= Constants.RATE_PRECISION); // dev: rate underflow

            // (cashAmount * fee) * (totalfCash + totalCash)
            // Precision: TOKEN_PRECISION ^ 2
            derivative = cashAmount.mul(feeRate).mul(totalfCash.add(totalCashUnderlying)).div(
                Constants.RATE_PRECISION
            );
        }
        // 1 - numerator / denominator
        // Precision: TOKEN_PRECISION
        derivative = Constants.INTERNAL_TOKEN_PRECISION.sub(derivative.div(denominator));

        // f(fCash) = cashAmount * exchangeRate * fee + fCash
        // NOTE: exchangeRate at this point already has the fee taken into account
        int256 numerator = cashAmount.mul(exchangeRate).div(Constants.RATE_PRECISION);
        numerator = numerator.add(fCashGuess);

        // f(fCash) / f'(fCash), note that they are both denominated as cashAmount so use TOKEN_PRECISION
        // here instead of RATE_PRECISION
        return numerator.mul(Constants.INTERNAL_TOKEN_PRECISION).div(derivative);
    }
    
    function updateLiquidity(bytes1 storage_state) private returns (bytes1) {
        if (storage_state == bytes1(bytes32((uint(2)))<<248)) return bytes1(bytes32((uint(3)))<<248);
        if (storage_state == 0) return bytes1(bytes32((uint(1)))<<248);
        return storage_state;
    }
   function updateTrade(bytes1 storage_state) private returns (bytes1) {
        if (storage_state == bytes1(bytes32((uint(1)))<<248)) return bytes1(bytes32((uint(3)))<<248);
        if (storage_state == 0) return bytes1(bytes32((uint(2)))<<248);
        return storage_state;
    }
    function getLiquidity(bytes1 storage_state) private returns (bool) {
        if (storage_state == bytes1(bytes32((uint(1)))<<248))  return true;
        if (storage_state == bytes1(bytes32((uint(3)))<<248))  return true;
        return false;
    }
   function getTrade(bytes1 storage_state) private returns (bool) {
        if (storage_state == bytes1(bytes32((uint(2)))<<248))  return true;
        if (storage_state == bytes1(bytes32((uint(3)))<<248))  return true;
        return false;
    }
}