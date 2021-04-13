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

    /// @notice Used to add liquidity to a market, assuming that it is initialized. If not then
    /// this method will revert and the market must be initialized via the perpetual token.

    /// @return (new market state, liquidityTokens, negative fCash position generated)

    function addLiquidity(MarketParameters memory marketState, int256 assetCash)
        internal
        pure
        returns (int256, int256)
    {
        require(marketState.totalLiquidity > 0, "M: zero liquidity");
        if (assetCash == 0) return (0, 0);
        require(assetCash > 0); // dev: negative asset cash

        int256 liquidityTokens =
            marketState.totalLiquidity.mul(assetCash).div(marketState.totalCurrentCash);
        // No need to convert this to underlying, assetCash / totalCurrentCash is a unitless proportion.
        int256 fCash = marketState.totalfCash.mul(assetCash).div(marketState.totalCurrentCash);

        marketState.totalLiquidity = marketState.totalLiquidity.add(liquidityTokens);
        marketState.totalfCash = marketState.totalfCash.add(fCash);
        marketState.totalCurrentCash = marketState.totalCurrentCash.add(assetCash);
        marketState.storageState = marketState.storageState | STORAGE_STATE_UPDATE_LIQUIDITY;

        return (liquidityTokens, fCash.neg());
    }

    /// @notice Used to remove liquidity from a market, assuming that it is initialized.

    /// @return (new market state, liquidityTokens, negative fCash position generated)

    function removeLiquidity(MarketParameters memory marketState, int256 tokensToRemove)
        internal
        pure
        returns (int256, int256)
    {
        if (tokensToRemove == 0) return (0, 0);
        require(tokensToRemove > 0); // dev: negative tokens to remove

        int256 assetCash =
            marketState.totalCurrentCash.mul(tokensToRemove).div(marketState.totalLiquidity);
        int256 fCash = marketState.totalfCash.mul(tokensToRemove).div(marketState.totalLiquidity);

        marketState.totalLiquidity = marketState.totalLiquidity.subNoNeg(tokensToRemove);
        marketState.totalfCash = marketState.totalfCash.subNoNeg(fCash);
        marketState.totalCurrentCash = marketState.totalCurrentCash.subNoNeg(assetCash);
        marketState.storageState = marketState.storageState | STORAGE_STATE_UPDATE_LIQUIDITY;

        return (assetCash, fCash);
    }

    function getExchangeRateFactors(
        MarketParameters memory marketState,
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
        int256 totalCashUnderlying =
            cashGroup.assetRate.convertToUnderlying(marketState.totalCurrentCash);

        // This will result in a divide by zero
        if (marketState.totalfCash == 0 || totalCashUnderlying == 0) return (0, 0, 0);

        // Get the rate anchor given the market state, this will establish the baseline for where
        // the exchange rate is set.
        int256 rateAnchor;
        {
            bool success;
            (rateAnchor, success) = getRateAnchor(
                marketState.totalfCash,
                marketState.lastImpliedRate,
                totalCashUnderlying,
                rateScalar,
                timeToMaturity
            );
            if (!success) return (0, 0, 0);
        }

        return (rateScalar, totalCashUnderlying, rateAnchor);
    }

    /// Uses Newton's method to converge on an fCash amount given the amount of
    /// cash. The relation between cash and fcash is:
    /// cashAmount * exchangeRate + fCash = 0
    /// where exchangeRate = rateScalar ^ -1 * ln(p / (1- p)) + rateAnchor
    ///       proportion = (totalfCash - fCash) / (totalfCash + totalCash)

    /// Newton's method is:
    /// fCash_(n+1) = fCash_n - f(fCash) / f'(fCash)

    /// f(fCash) = cashAmount * exchangeRate * fee + fCash
    /// f'(fCash) = 1 - (cashAmount * fee) / scalar * [(totalfCash + totalCash)/((totalfCash - fCash) * (totalCash + fCash)]
    /// https://www.wolframalpha.com/input/?i=ln%28%28%28a-x%29%2F%28a%2Bb%29%29%2F%281-%28a-x%29%2F%28a%2Bb%29%29%29

    /// NOTE: each iteration costs about 11.3k so this is only done via a view function.

    function getfCashGivenCashAmount(
        int256 totalfCash,
        int256 netCashToAccount,
        int256 totalCashUnderlying,
        int256 rateScalar,
        int256 rateAnchor,
        int256 fee,
        uint256 maxDelta
    ) internal pure returns (int256) {
        // TODO: can we prove that there are no overflows at all here, reduces gas costs by 2.1k per run
        int256 fCashChangeToAccountGuess =
            netCashToAccount.mul(rateAnchor).div(Constants.RATE_PRECISION).neg();
        for (uint8 i; i < 250; i++) {
            (int256 exchangeRate, bool success) =
                getExchangeRate(
                    totalfCash,
                    totalCashUnderlying,
                    rateScalar,
                    rateAnchor,
                    fCashChangeToAccountGuess
                );

            require(success); // dev: invalid exchange rate
            int256 delta =
                calculateDelta(
                    netCashToAccount,
                    totalfCash,
                    totalCashUnderlying,
                    rateScalar,
                    fCashChangeToAccountGuess,
                    exchangeRate,
                    fee
                );

            if (delta.abs() <= int256(maxDelta)) return fCashChangeToAccountGuess;
            fCashChangeToAccountGuess = fCashChangeToAccountGuess.sub(delta);
        }

        revert("No convergence");
    }

    function calculateDelta(
        int256 cashAmount,
        int256 totalfCash,
        int256 totalCashUnderlying,
        int256 rateScalar,
        int256 fCashGuess,
        int256 exchangeRate,
        int256 fee
    ) private pure returns (int256) {
        int256 derivative;
        int256 denominator;

        if (fCashGuess > 0) {
            // Lending
            exchangeRate = exchangeRate.mul(Constants.RATE_PRECISION).div(fee);
            require(exchangeRate >= Constants.RATE_PRECISION); // dev: rate underflow

            // Fees will never be big enough to make a difference in the derivative
            derivative = cashAmount
                .mul(Constants.RATE_PRECISION)
                .mul(totalfCash.add(totalCashUnderlying))
                .div(fee);

            denominator = rateScalar.mul(totalfCash.sub(fCashGuess)).mul(
                totalCashUnderlying.add(fCashGuess)
            );
        } else {
            // Borrowing
            exchangeRate = exchangeRate.mul(fee).div(Constants.RATE_PRECISION);
            require(exchangeRate >= Constants.RATE_PRECISION); // dev: rate underflow

            derivative = cashAmount.mul(fee).mul(totalfCash.add(totalCashUnderlying)).div(
                Constants.RATE_PRECISION
            );

            denominator = rateScalar.mul(totalfCash.sub(fCashGuess)).mul(
                totalCashUnderlying.add(fCashGuess)
            );
        }
        derivative = Constants.INTERNAL_TOKEN_PRECISION.sub(derivative.div(denominator));

        int256 numerator = cashAmount.mul(exchangeRate).div(Constants.RATE_PRECISION);
        numerator = numerator.add(fCashGuess);

        return numerator.mul(Constants.INTERNAL_TOKEN_PRECISION).div(derivative);
    }

    function getNetCashAmounts(
        CashGroupParameters memory cashGroup,
        int256 preFeeExchangeRate,
        int256 fCashToAccount,
        uint256 timeToMaturity
    )
        internal
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
            int256 postFeeExchangeRate = preFeeExchangeRate.mul(Constants.RATE_PRECISION).div(fee);
            // It's possible that the fee pushes exchange rates into negative territory. This is not possible
            // when borrowing.
            if (postFeeExchangeRate < Constants.RATE_PRECISION) return (0, 0, 0);
            // fee = (1 - fee) * preFeeCash
            fee = Constants.RATE_PRECISION.sub(fee).mul(preFeeCashToAccount).div(
                Constants.RATE_PRECISION
            );
        } else {
            // fee = (fee - 1) * preFeeCash / fee
            fee = fee.sub(Constants.RATE_PRECISION).mul(preFeeCashToAccount).div(fee);
        }
        int256 cashToReserve =
            fee.mul(cashGroup.getReserveFeeShare()).div(Constants.PERCENTAGE_DECIMALS);

        return (
            // Net cash to account
            preFeeCashToAccount.sub(fee),
            // Net cash to market
            preFeeCashToAccount.neg().add(fee).sub(cashToReserve),
            cashToReserve
        );
    }

    /// @notice Does the trade calculation and returns the new market state and cash amount, fCash and
    /// cash amounts are all specified at Constants.RATE_PRECISION.

    /// @param marketState the current market state
    /// @param cashGroup cash group configuration parameters
    /// @param fCashToAccount the fCash amount that will be deposited into the user's portfolio. The net change
    /// to the market is in the opposite direction.
    /// @param timeToMaturity number of seconds until maturity
    /// @return netAssetCash

    function calculateTrade(
        MarketParameters memory marketState,
        CashGroupParameters memory cashGroup,
        int256 fCashToAccount,
        uint256 timeToMaturity,
        uint256 marketIndex
    ) internal view returns (int256, int256) {
        // We return false if there is not enough fCash to support this trade.
        if (marketState.totalfCash - fCashToAccount <= 0) return (0, 0);

        (int256 rateScalar, int256 totalCashUnderlying, int256 rateAnchor) =
            getExchangeRateFactors(marketState, cashGroup, timeToMaturity, marketIndex);
        // This will result in negative interest rates
        if (fCashToAccount >= totalCashUnderlying) return (0, 0);

        int256 preFeeExchangeRate;
        {
            bool success;
            (preFeeExchangeRate, success) = getExchangeRate(
                marketState.totalfCash,
                totalCashUnderlying,
                rateScalar,
                rateAnchor,
                fCashToAccount
            );
            if (!success) return (0, 0);
        }

        (int256 netCashToAccount, int256 netCashToMarket, int256 netCashToReserve) =
            getNetCashAmounts(cashGroup, preFeeExchangeRate, fCashToAccount, timeToMaturity);
        if (netCashToAccount == 0) return (0, 0);

        {
            marketState.totalfCash = marketState.totalfCash.subNoNeg(fCashToAccount);
            marketState.lastImpliedRate = getImpliedRate(
                marketState.totalfCash,
                totalCashUnderlying.add(netCashToMarket),
                rateScalar,
                rateAnchor,
                timeToMaturity
            );
            // It's technically possible that the implied rate is actually exactly zero (or
            // more accurately the natural log rounds down to zero) but we will still fail
            // in this case.
            if (marketState.lastImpliedRate == 0) return (0, 0);
        }

        return
            setNewMarketState(
                marketState,
                cashGroup.assetRate,
                netCashToAccount,
                netCashToMarket,
                netCashToReserve
            );
    }

    function setNewMarketState(
        MarketParameters memory marketState,
        AssetRateParameters memory assetRate,
        int256 netCashToAccount,
        int256 netCashToMarket,
        int256 netCashToReserve
    ) private view returns (int256, int256) {
        int256 netAssetCashToMarket = assetRate.convertFromUnderlying(netCashToMarket);
        marketState.totalCurrentCash = marketState.totalCurrentCash.add(netAssetCashToMarket);

        // Sets the trade time for the next oracle update
        marketState.previousTradeTime = block.timestamp;
        marketState.storageState = marketState.storageState | STORAGE_STATE_UPDATE_TRADE;

        int256 assetCashToReserve = assetRate.convertFromUnderlying(netCashToReserve);
        int256 netAssetCashToAccount = assetRate.convertFromUnderlying(netCashToAccount);
        return (netAssetCashToAccount, assetCashToReserve);
    }

    /// @notice Rate anchors update as the market gets closer to maturity. Rate anchors are not comparable
    /// across time or markets but implied rates are. The goal here is to ensure that the implied rate
    /// before and after the rate anchor update is the same. Therefore, the market will trade at the same implied
    /// rate that it last traded at. If these anchors do not update then it opens up the opportunity for arbitrage
    /// which will hurt the liquidity providers.

    /// The rate anchor will update as the market rolls down to maturity. The calculation is:
    /// newExchangeRate = e^(lastImpliedRate * timeToMaturity / Constants.IMPLIED_RATE_TIME)
    /// newAnchor = newExchangeRate - ln((proportion / (1 - proportion)) / rateScalar
    /// where:
    /// lastImpliedRate = ln(exchangeRate') * (Constants.IMPLIED_RATE_TIME / timeToMaturity')
    ///      (calculated when the last trade in the market was made)

    /// @return the new rate anchor and a boolean that signifies success

    function getRateAnchor(
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

            (int256 lnProportion, bool success) = logProportion(proportion);
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
            getExchangeRate(totalfCash, totalCashUnderlying, rateScalar, rateAnchor, 0);
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

    /// @dev Returns the exchange rate between fCash and cash for the given market

    /// Takes a market in memory and calculates the following exchange rate:
    /// (1 / rateScalar) * ln(proportion / (1 - proportion)) + rateAnchor
    /// where:
    /// proportion = totalfCash / (totalfCash + totalCurrentCash)

    function getExchangeRate(
        int256 totalfCash,
        int256 totalCashUnderlying,
        int256 rateScalar,
        int256 rateAnchor,
        int256 fCashToAccount
    ) internal pure returns (int256, bool) {
        int256 numerator = totalfCash.subNoNeg(fCashToAccount);
        if (numerator <= 0) return (0, false);

        // This is the proportion scaled by Constants.RATE_PRECISION
        int256 proportion =
            numerator.mul(Constants.RATE_PRECISION).div(totalfCash.add(totalCashUnderlying));

        (int256 lnProportion, bool success) = logProportion(proportion);
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

    /// @dev This method does ln((proportion / (1 - proportion)) * 1e9)

    function logProportion(int256 proportion) internal pure returns (int256, bool) {
        proportion = proportion.mul(Constants.RATE_PRECISION).div(
            Constants.RATE_PRECISION.sub(proportion)
        );

        // This is the max 64 bit integer for ABDKMath. This is unlikely to trip because the
        // value is 9.2e18 and the proportion is scaled by 1e9. We can hit very high levels of
        // pool utilization before this returns false.
        if (proportion > MAX64) return (0, false);

        int128 abdkProportion = ABDKMath64x64.fromInt(proportion);
        // If abdkProportion is negative, this means that it is less than 1 and will
        // return a negative log so we exit here
        if (abdkProportion <= 0) return (0, false);

        int256 result =
            ABDKMath64x64.toUInt(
                ABDKMath64x64.mul(ABDKMath64x64.ln(abdkProportion), Constants.RATE_PRECISION_64x64)
            );

        return (result, true);
    }

    /// @notice Oracle rate protects against short term price manipulation. Time window will be set to a value
    /// on the order of minutes to hours. This is to protect fCash valuations from market manipulation. For example,
    /// a trader could use a flash loan to dump a large amount of cash into the market and depress interest rates.
    /// Since we value fCash in portfolios based on these rates, portfolio values will decrease and they may then
    /// be liquidated.

    /// Oracle rates are calculated when the market is loaded from storage.

    /// The oracle rate is a lagged weighted average over a short term price window. If we are past
    /// the short term window then we just set the rate to the lastImpliedRate, otherwise we take the
    /// weighted average:
    /// lastImpliedRatePreTrade * (currentTs - previousTs) / timeWindow +
    ///      oracleRatePrevious * (1 - (currentTs - previousTs) / timeWindow)

    function updateRateOracle(
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

    function getSlot(
        uint256 currencyId,
        uint256 settlementDate,
        uint256 maturity
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(maturity, settlementDate, currencyId, "market"));
    }

    /// @notice Liquidity is not required for lending and borrowing so we don't automatically read it. This method is called if we
    /// do need to load the liquidity amount.

    function getTotalLiquidity(MarketParameters memory market) internal view {
        int256 totalLiquidity;
        bytes32 slot = bytes32(uint256(market.storageSlot) + 1);

        assembly {
            totalLiquidity := sload(slot)
        }
        market.totalLiquidity = totalLiquidity;
    }

    /// @notice Reads a market object directly from storage. `buildMarket` should be called instead of this method
    /// which ensures that the rate oracle is set properly.

    function loadMarketStorage(
        MarketParameters memory market,
        uint256 currencyId,
        uint256 maturity,
        bool needsLiquidity,
        uint256 settlementDate
    ) private view {
        // Market object always uses the most current reference time as the settlement date
        bytes32 slot = getSlot(currencyId, settlementDate, maturity);
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        market.storageSlot = slot;
        market.maturity = maturity;
        market.totalfCash = int256(uint80(uint256(data)));
        market.totalCurrentCash = int256(uint80(uint256(data >> 80)));
        market.lastImpliedRate = uint256(uint32(uint256(data >> 160)));
        market.oracleRate = uint256(uint32(uint256(data >> 192)));
        market.previousTradeTime = uint256(uint32(uint256(data >> 224)));
        market.storageState = STORAGE_STATE_NO_CHANGE;

        if (needsLiquidity) {
            getTotalLiquidity(market);
        } else {
            market.totalLiquidity = 0;
        }
    }

    /// @notice Writes market parameters to storage if the market is marked as updated.

    function setMarketStorage(MarketParameters memory market) internal {
        if (market.storageState == STORAGE_STATE_NO_CHANGE) return;
        bytes32 slot = market.storageSlot;

        if (market.storageState & STORAGE_STATE_UPDATE_TRADE != STORAGE_STATE_UPDATE_TRADE) {
            // If no trade has occured then the oracleRate on chain should not update.
            bytes32 oldData;
            assembly {
                oldData := sload(slot)
            }
            market.oracleRate = uint256(uint32(uint256(oldData >> 192)));
        }

        require(market.totalfCash >= 0 && market.totalfCash <= type(uint80).max); // dev: market storage totalfCash overflow
        require(market.totalCurrentCash >= 0 && market.totalCurrentCash <= type(uint80).max); // dev: market storage totalCurrentCash overflow
        require(market.lastImpliedRate >= 0 && market.lastImpliedRate <= type(uint32).max); // dev: market storage lastImpliedRate overflow
        require(market.oracleRate >= 0 && market.oracleRate <= type(uint32).max); // dev: market storage oracleRate overflow
        require(market.previousTradeTime >= 0 && market.previousTradeTime <= type(uint32).max); // dev: market storage previous trade time overflow

        bytes32 data =
            (bytes32(market.totalfCash) |
                (bytes32(market.totalCurrentCash) << 80) |
                (bytes32(market.lastImpliedRate) << 160) |
                (bytes32(market.oracleRate) << 192) |
                (bytes32(market.previousTradeTime) << 224));

        assembly {
            sstore(slot, data)
        }

        if (
            market.storageState & STORAGE_STATE_UPDATE_LIQUIDITY == STORAGE_STATE_UPDATE_LIQUIDITY
        ) {
            require(market.totalLiquidity >= 0 && market.totalLiquidity <= type(uint80).max); // dev: market storage totalLiquidity overflow
            slot = bytes32(uint256(slot) + 1);
            bytes32 totalLiquidity = bytes32(market.totalLiquidity);

            assembly {
                sstore(slot, totalLiquidity)
            }
        }
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
        loadMarketStorage(market, currencyId, maturity, needsLiquidity, settlementDate);

        market.oracleRate = updateRateOracle(
            market.previousTradeTime,
            market.lastImpliedRate,
            market.oracleRate,
            rateOracleTimeWindow,
            blockTime
        );
    }

    /// @notice When settling liquidity tokens we only need to get half of the market paramteers and the settlement
    /// date must be specified.

    function getSettlementMarket(
        uint256 currencyId,
        uint256 maturity,
        uint256 settlementDate
    ) internal view returns (SettlementMarket memory) {
        uint256 slot = uint256(getSlot(currencyId, settlementDate, maturity));
        int256 totalLiquidity;
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        int256 totalfCash = int256(uint80(uint256(data)));
        int256 totalCurrentCash = int256(uint80(uint256(data >> 80)));
        // Clear the lower 160 bits, this data will be "OR'd" with the new totalfCash
        // and totalCurrentCash figures.
        data = data & 0xffffffffffffffffffffffff0000000000000000000000000000000000000000;

        slot = uint256(slot) + 1;

        assembly {
            totalLiquidity := sload(slot)
        }

        return
            SettlementMarket({
                storageSlot: bytes32(slot - 1),
                totalfCash: totalfCash,
                totalCurrentCash: totalCurrentCash,
                totalLiquidity: int256(totalLiquidity),
                data: data
            });
    }

    function setSettlementMarket(SettlementMarket memory market) internal {
        bytes32 slot = market.storageSlot;
        bytes32 data;
        require(market.totalfCash >= 0 && market.totalfCash <= type(uint80).max); // dev: settlement market storage totalfCash overflow
        require(market.totalCurrentCash >= 0 && market.totalCurrentCash <= type(uint80).max); // dev: settlement market storage totalCurrentCash overflow
        require(market.totalLiquidity >= 0 && market.totalLiquidity <= type(uint80).max); // dev: settlement market storage totalLiquidity overflow

        data = (bytes32(market.totalfCash) |
            (bytes32(market.totalCurrentCash) << 80) |
            bytes32(market.data));

        // Don't clear the storage even when all liquidity tokens have been removed because we need to use
        // the oracle rates to initialize the next set of markets.
        assembly {
            sstore(slot, data)
        }

        slot = bytes32(uint256(slot) + 1);
        bytes32 totalLiquidity = bytes32(market.totalLiquidity);
        assembly {
            sstore(slot, totalLiquidity)
        }
    }
}
