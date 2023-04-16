// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./AssetRate.sol";
import "./CashGroup.sol";
import "./DateTime.sol";
import "../balances/BalanceHandler.sol";
import "../../global/LibStorage.sol";
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

    // Max positive value for a ABDK64x64 integer
    int256 private constant MAX64 = 0x7FFFFFFFFFFFFFFF;

    /// @notice Add liquidity to a market, assuming that it is initialized. If not then
    /// this method will revert and the market must be initialized first.
    /// Return liquidityTokens and negative fCash to the portfolio
    function addLiquidity(MarketParameters memory market, int256 assetCash)
        internal
        returns (int256 liquidityTokens, int256 fCash)
    {
        require(market.totalLiquidity > 0, "M: zero liquidity");
        if (assetCash == 0) return (0, 0);
        require(assetCash > 0); // dev: negative asset cash

        liquidityTokens = market.totalLiquidity.mul(assetCash).div(market.totalAssetCash);
        // No need to convert this to underlying, assetCash / totalAssetCash is a unitless proportion.
        fCash = market.totalfCash.mul(assetCash).div(market.totalAssetCash);

        market.totalLiquidity = market.totalLiquidity.add(liquidityTokens);
        market.totalfCash = market.totalfCash.add(fCash);
        market.totalAssetCash = market.totalAssetCash.add(assetCash);
        _setMarketStorageForLiquidity(market);
        // Flip the sign to represent the LP's net position
        fCash = fCash.neg();
    }

    /// @notice Remove liquidity from a market, assuming that it is initialized.
    /// Return assetCash and positive fCash to the portfolio
    function removeLiquidity(MarketParameters memory market, int256 tokensToRemove)
        internal
        returns (int256 assetCash, int256 fCash)
    {
        if (tokensToRemove == 0) return (0, 0);
        require(tokensToRemove > 0); // dev: negative tokens to remove

        assetCash = market.totalAssetCash.mul(tokensToRemove).div(market.totalLiquidity);
        fCash = market.totalfCash.mul(tokensToRemove).div(market.totalLiquidity);

        market.totalLiquidity = market.totalLiquidity.subNoNeg(tokensToRemove);
        market.totalfCash = market.totalfCash.subNoNeg(fCash);
        market.totalAssetCash = market.totalAssetCash.subNoNeg(assetCash);

        _setMarketStorageForLiquidity(market);
    }

    function executeTrade(
        MarketParameters memory market,
        CashGroupParameters memory cashGroup,
        int256 fCashToAccount,
        uint256 timeToMaturity,
        uint256 marketIndex
    ) internal returns (int256 netAssetCash) {
        int256 netAssetCashToReserve;
        (netAssetCash, netAssetCashToReserve) = calculateTrade(
            market,
            cashGroup,
            fCashToAccount,
            timeToMaturity,
            marketIndex
        );

        if (netAssetCash != 0) {
            MarketStorage storage marketStorage = _getMarketStoragePointer(market);
            _setMarketStorage(
                marketStorage,
                market.totalfCash,
                market.totalAssetCash,
                market.lastImpliedRate,
                market.oracleRate,
                market.previousTradeTime
            );
            BalanceHandler.incrementFeeToReserve(cashGroup.currencyId, netAssetCashToReserve);
        }
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
        MarketParameters memory market,
        CashGroupParameters memory cashGroup,
        int256 fCashToAccount,
        uint256 timeToMaturity,
        uint256 marketIndex
    ) internal view returns (int256, int256) {
        // We return false if there is not enough fCash to support this trade.
        // if fCashToAccount > 0 and totalfCash - fCashToAccount <= 0 then the trade will fail
        // if fCashToAccount < 0 and totalfCash > 0 then this will always pass
        if (market.totalfCash <= fCashToAccount) return (0, 0);

        // Calculates initial rate factors for the trade
        (int256 rateScalar, int256 totalCashUnderlying, int256 rateAnchor) =
            getExchangeRateFactors(market, cashGroup, timeToMaturity, marketIndex);

        // Calculates the exchange rate from cash to fCash before any liquidity fees
        // are applied
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

        // Given the exchange rate, returns the net cash amounts to apply to each of the
        // three relevant balances.
        (int256 netCashToAccount, int256 netCashToMarket, int256 netCashToReserve) =
            _getNetCashAmountsUnderlying(
                cashGroup,
                preFeeExchangeRate,
                fCashToAccount,
                timeToMaturity
            );
        // Signifies a failed net cash amount calculation
        if (netCashToAccount == 0) return (0, 0);

        {
            // Set the new implied interest rate after the trade has taken effect, this
            // will be used to calculate the next trader's interest rate.
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
    /// @return
    ///    rateScalar: a scalar value in rate precision that defines the slope of the line
    ///    totalCashUnderlying: the converted asset cash to underlying cash for calculating
    ///    the exchange rates for the trade
    ///    rateAnchor: an offset from the x axis to maintain interest rate continuity over time
    function getExchangeRateFactors(
        MarketParameters memory market,
        CashGroupParameters memory cashGroup,
        uint256 timeToMaturity,
        uint256 marketIndex
    )
        internal
        pure
        returns (
            int256,
            int256,
            int256
        )
    {
        int256 rateScalar = cashGroup.getRateScalar(marketIndex, timeToMaturity);
        int256 totalCashUnderlying = cashGroup.assetRate.convertToUnderlying(market.totalAssetCash);

        // This would result in a divide by zero
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
    /// @return
    ///     netCashToAccount: this is a positive or negative amount of cash change to the account
    ///     netCashToMarket: this is a positive or negative amount of cash change in the market
    //      netCashToReserve: this is always a positive amount of cash accrued to the reserve
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
        // Fees are specified in basis points which is an rate precision denomination. We convert this to
        // an exchange rate denomination for the given time to maturity. (i.e. get e^(fee * t) and multiply
        // or divide depending on the side of the trade).
        // tradeExchangeRate = exp((tradeInterestRateNoFee +/- fee) * timeToMaturity)
        // tradeExchangeRate = tradeExchangeRateNoFee (* or /) exp(fee * timeToMaturity)
        // cash = fCash / exchangeRate, exchangeRate > 1
        int256 preFeeCashToAccount =
            fCashToAccount.divInRatePrecision(preFeeExchangeRate).neg();
        int256 fee = getExchangeRateFromImpliedRate(cashGroup.getTotalFee(), timeToMaturity);

        if (fCashToAccount > 0) {
            // Lending
            // Dividing reduces exchange rate, lending should receive less fCash for cash
            int256 postFeeExchangeRate = preFeeExchangeRate.divInRatePrecision(fee);
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
            // RATE_PRECISION - fee will be negative here, preFeeCashToAccount < 0, fee > 0
            fee = preFeeCashToAccount.mulInRatePrecision(Constants.RATE_PRECISION.sub(fee));
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
            // preFee * (1 - fee) / fee will be negative, use neg() to flip to positive
            // RATE_PRECISION - fee will be negative
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

    /// @notice Sets the new market state
    /// @return
    ///     netAssetCashToAccount: the positive or negative change in asset cash to the account
    ///     assetCashToReserve: the positive amount of cash that accrues to the reserve
    function _setNewMarketState(
        MarketParameters memory market,
        AssetRateParameters memory assetRate,
        int256 netCashToAccount,
        int256 netCashToMarket,
        int256 netCashToReserve
    ) private view returns (int256, int256) {
        int256 netAssetCashToMarket = assetRate.convertFromUnderlying(netCashToMarket);
        // Set storage checks that total asset cash is above zero
        market.totalAssetCash = market.totalAssetCash.add(netAssetCashToMarket);

        // Sets the trade time for the next oracle update
        market.previousTradeTime = block.timestamp;
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
    /// @return the new rate anchor and a boolean that signifies success
    function _getRateAnchor(
        int256 totalfCash,
        uint256 lastImpliedRate,
        int256 totalCashUnderlying,
        int256 rateScalar,
        uint256 timeToMaturity
    ) internal pure returns (int256, bool) {
        // This is the exchange rate at the new time to maturity
        int256 newExchangeRate = getExchangeRateFromImpliedRate(lastImpliedRate, timeToMaturity);
        if (newExchangeRate < Constants.RATE_PRECISION) return (0, false);

        int256 rateAnchor;
        {
            // totalfCash / (totalfCash + totalCashUnderlying)
            int256 proportion =
                totalfCash.divInRatePrecision(totalfCash.add(totalCashUnderlying));

            (int256 lnProportion, bool success) = _logProportion(proportion);
            if (!success) return (0, false);

            // newExchangeRate - ln(proportion / (1 - proportion)) / rateScalar
            rateAnchor = newExchangeRate.sub(lnProportion.divInRatePrecision(rateScalar));
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
        // Scales down to a floating point for LN
        int128 rateScaled = ABDKMath64x64.div(rate, Constants.RATE_PRECISION_64x64);
        // We will not have a negative log here because we check that exchangeRate > Constants.RATE_PRECISION
        // inside getExchangeRate
        int128 lnRateScaled = ABDKMath64x64.ln(rateScaled);
        // Scales up to a fixed point
        uint256 lnRate =
            ABDKMath64x64.toUInt(ABDKMath64x64.mul(lnRateScaled, Constants.RATE_PRECISION_64x64));

        // lnRate * IMPLIED_RATE_TIME / ttm
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
        // (totalfCash + fCash) / (totalfCash + totalCashUnderlying)
        int256 proportion =
            numerator.divInRatePrecision(totalfCash.add(totalCashUnderlying));

        // This limit is here to prevent the market from reaching extremely high interest rates via an
        // excessively large proportion (high amounts of fCash relative to cash).
        // Market proportion can only increase via borrowing (fCash is added to the market and cash is
        // removed). Over time, the returns from asset cash will slightly decrease the proportion (the
        // value of cash underlying in the market must be monotonically increasing). Therefore it is not
        // possible for the proportion to go over max market proportion unless borrowing occurs.
        if (proportion > Constants.MAX_MARKET_PROPORTION) return (0, false);

        (int256 lnProportion, bool success) = _logProportion(proportion);
        if (!success) return (0, false);

        // lnProportion / rateScalar + rateAnchor
        int256 rate = lnProportion.divInRatePrecision(rateScalar).add(rateAnchor);
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
    function _logProportion(int256 proportion) internal pure returns (int256, bool) {
        // This will result in divide by zero, short circuit
        if (proportion == Constants.RATE_PRECISION) return (0, false);

        // Convert proportion to what is used inside the logit function (p / (1-p))
        int256 logitP = proportion.divInRatePrecision(Constants.RATE_PRECISION.sub(proportion));

        // ABDK does not handle log of numbers that are less than 1, in order to get the right value
        // scaled by RATE_PRECISION we use the log identity:
        // (ln(logitP / RATE_PRECISION)) * RATE_PRECISION = (ln(logitP) - ln(RATE_PRECISION)) * RATE_PRECISION
        int128 abdkProportion = ABDKMath64x64.fromInt(logitP);
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
    }

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

    function getOracleRate(
        uint256 currencyId,
        uint256 maturity,
        uint256 rateOracleTimeWindow,
        uint256 blockTime
    ) internal view returns (uint256) {
        mapping(uint256 => mapping(uint256 => 
            mapping(uint256 => MarketStorage))) storage store = LibStorage.getMarketStorage();
        uint256 settlementDate = DateTime.getReferenceTime(blockTime) + Constants.QUARTER;
        MarketStorage storage marketStorage = store[currencyId][maturity][settlementDate];

        uint256 lastImpliedRate = marketStorage.lastImpliedRate;
        uint256 oracleRate = marketStorage.oracleRate;
        uint256 previousTradeTime = marketStorage.previousTradeTime;

        // If the oracle rate is set to zero this can only be because the markets have past their settlement
        // date but the new set of markets has not yet been initialized. This means that accounts cannot be liquidated
        // during this time, but market initialization can be called by anyone so the actual time that this condition
        // exists for should be quite short.
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

    /// @notice Reads a market object directly from storage. `loadMarket` should be called instead of this method
    /// which ensures that the rate oracle is set properly.
    function _loadMarketStorage(
        MarketParameters memory market,
        uint256 currencyId,
        uint256 maturity,
        bool needsLiquidity,
        uint256 settlementDate
    ) private view {
        // Market object always uses the most current reference time as the settlement date
        mapping(uint256 => mapping(uint256 => 
            mapping(uint256 => MarketStorage))) storage store = LibStorage.getMarketStorage();
        MarketStorage storage marketStorage = store[currencyId][maturity][settlementDate];
        bytes32 slot;
        assembly {
            slot := marketStorage.slot
        }

        market.storageSlot = slot;
        market.maturity = maturity;
        market.totalfCash = marketStorage.totalfCash;
        market.totalAssetCash = marketStorage.totalAssetCash;
        market.lastImpliedRate = marketStorage.lastImpliedRate;
        market.oracleRate = marketStorage.oracleRate;
        market.previousTradeTime = marketStorage.previousTradeTime;

        if (needsLiquidity) {
            market.totalLiquidity = marketStorage.totalLiquidity;
        } else {
            market.totalLiquidity = 0;
        }
    }

    function _getMarketStoragePointer(
        MarketParameters memory market
    ) private pure returns (MarketStorage storage marketStorage) {
        bytes32 slot = market.storageSlot;
        assembly {
            marketStorage.slot := slot
        }
    }

    function _setMarketStorageForLiquidity(MarketParameters memory market) internal {
        MarketStorage storage marketStorage = _getMarketStoragePointer(market);
        // Oracle rate does not change on liquidity
        uint32 storedOracleRate = marketStorage.oracleRate;

        _setMarketStorage(
            marketStorage,
            market.totalfCash,
            market.totalAssetCash,
            market.lastImpliedRate,
            storedOracleRate,
            market.previousTradeTime
        );

        _setTotalLiquidity(marketStorage, market.totalLiquidity);
    }

    function setMarketStorageForInitialize(
        MarketParameters memory market,
        uint256 currencyId,
        uint256 settlementDate
    ) internal {
        // On initialization we have not yet calculated the storage slot so we get it here.
        mapping(uint256 => mapping(uint256 => 
            mapping(uint256 => MarketStorage))) storage store = LibStorage.getMarketStorage();
        MarketStorage storage marketStorage = store[currencyId][market.maturity][settlementDate];

        _setMarketStorage(
            marketStorage,
            market.totalfCash,
            market.totalAssetCash,
            market.lastImpliedRate,
            market.oracleRate,
            market.previousTradeTime
        );

        _setTotalLiquidity(marketStorage, market.totalLiquidity);
    }

    function _setTotalLiquidity(
        MarketStorage storage marketStorage,
        int256 totalLiquidity
    ) internal {
        require(totalLiquidity >= 0 && totalLiquidity <= type(uint80).max); // dev: market storage totalLiquidity overflow
        marketStorage.totalLiquidity = uint80(totalLiquidity);
    }

    function _setMarketStorage(
        MarketStorage storage marketStorage,
        int256 totalfCash,
        int256 totalAssetCash,
        uint256 lastImpliedRate,
        uint256 oracleRate,
        uint256 previousTradeTime
    ) private {
        require(totalfCash >= 0 && totalfCash <= type(uint80).max); // dev: storage totalfCash overflow
        require(totalAssetCash >= 0 && totalAssetCash <= type(uint80).max); // dev: storage totalAssetCash overflow
        require(0 < lastImpliedRate && lastImpliedRate <= type(uint32).max); // dev: storage lastImpliedRate overflow
        require(0 < oracleRate && oracleRate <= type(uint32).max); // dev: storage oracleRate overflow
        require(0 <= previousTradeTime && previousTradeTime <= type(uint32).max); // dev: storage previous trade time overflow

        marketStorage.totalfCash = uint80(totalfCash);
        marketStorage.totalAssetCash = uint80(totalAssetCash);
        marketStorage.lastImpliedRate = uint32(lastImpliedRate);
        marketStorage.oracleRate = uint32(oracleRate);
        marketStorage.previousTradeTime = uint32(previousTradeTime);
    }

    /// @notice Creates a market object and ensures that the rate oracle time window is updated appropriately.
    function loadMarket(
        MarketParameters memory market,
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime,
        bool needsLiquidity,
        uint256 rateOracleTimeWindow
    ) internal view {
        // Always reference the current settlement date
        uint256 settlementDate = DateTime.getReferenceTime(blockTime) + Constants.QUARTER;
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
        MarketParameters memory market,
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime,
        bool needsLiquidity,
        uint256 rateOracleTimeWindow,
        uint256 settlementDate
    ) internal view {
        _loadMarketStorage(market, currencyId, maturity, needsLiquidity, settlementDate);

        market.oracleRate = _updateRateOracle(
            market.previousTradeTime,
            market.lastImpliedRate,
            market.oracleRate,
            rateOracleTimeWindow,
            blockTime
        );
    }

    function loadSettlementMarket(
        MarketParameters memory market,
        uint256 currencyId,
        uint256 maturity,
        uint256 settlementDate
    ) internal view {
        _loadMarketStorage(market, currencyId, maturity, true, settlementDate);
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
    function getfCashGivenCashAmount(
        int256 totalfCash,
        int256 netCashToAccount,
        int256 totalCashUnderlying,
        int256 rateScalar,
        int256 rateAnchor,
        int256 feeRate,
        int256 maxDelta
    ) internal pure returns (int256) {
        require(maxDelta >= 0);
        int256 fCashChangeToAccountGuess = netCashToAccount.mulInRatePrecision(rateAnchor).neg();
        for (uint8 i = 0; i < 250; i++) {
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

            if (delta.abs() <= maxDelta) return fCashChangeToAccountGuess;
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
            rateScalar.mulInRatePrecision(
                (totalfCash.sub(fCashGuess)).mul(totalCashUnderlying.add(fCashGuess))
            );

        if (fCashGuess > 0) {
            // Lending
            exchangeRate = exchangeRate.divInRatePrecision(feeRate);
            require(exchangeRate >= Constants.RATE_PRECISION); // dev: rate underflow

            // (cashAmount / fee) * (totalfCash + totalCash)
            // Precision: TOKEN_PRECISION ^ 2
            derivative = cashAmount
                .mul(totalfCash.add(totalCashUnderlying))
                .divInRatePrecision(feeRate);
        } else {
            // Borrowing
            exchangeRate = exchangeRate.mulInRatePrecision(feeRate);
            require(exchangeRate >= Constants.RATE_PRECISION); // dev: rate underflow

            // (cashAmount * fee) * (totalfCash + totalCash)
            // Precision: TOKEN_PRECISION ^ 2
            derivative = cashAmount.mulInRatePrecision(
                feeRate.mul(totalfCash.add(totalCashUnderlying))
            );
        }
        // 1 - numerator / denominator
        // Precision: TOKEN_PRECISION
        derivative = Constants.INTERNAL_TOKEN_PRECISION.sub(derivative.div(denominator));

        // f(fCash) = cashAmount * exchangeRate * fee + fCash
        // NOTE: exchangeRate at this point already has the fee taken into account
        int256 numerator = cashAmount.mulInRatePrecision(exchangeRate);
        numerator = numerator.add(fCashGuess);

        // f(fCash) / f'(fCash), note that they are both denominated as cashAmount so use TOKEN_PRECISION
        // here instead of RATE_PRECISION
        return numerator.mul(Constants.INTERNAL_TOKEN_PRECISION).div(derivative);
    }
}
