// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {LibStorage} from "../../global/LibStorage.sol";
import {
    InterestRateCurveSettings,
    InterestRateParameters,
    CashGroupParameters,
    MarketParameters,
    PrimeRate
} from "../../global/Types.sol";
import {CashGroup} from "./CashGroup.sol";
import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {ABDKMath64x64} from "../../math/ABDKMath64x64.sol";

library InterestRateCurve {
    using SafeInt256 for int256;
    using SafeUint256 for uint256;
    using CashGroup for CashGroupParameters;
    using PrimeRateLib for PrimeRate;

    uint8 private constant PRIME_CASH_OFFSET = 0;
    uint8 private constant PRIME_CASH_SHIFT = 192;

    uint256 private constant KINK_UTILIZATION_1_BYTE = 0;
    uint256 private constant KINK_UTILIZATION_2_BYTE = 1;
    uint256 private constant MAX_RATE_BYTE           = 2;
    uint256 private constant KINK_RATE_1_BYTE        = 3;
    uint256 private constant KINK_RATE_2_BYTE        = 4;
    uint256 private constant MIN_FEE_RATE_BYTE       = 5;
    uint256 private constant MAX_FEE_RATE_BYTE       = 6;
    uint256 private constant FEE_RATE_PERCENT_BYTE   = 7;

    uint256 private constant KINK_UTILIZATION_1_BIT = KINK_UTILIZATION_1_BYTE * 8;
    uint256 private constant KINK_UTILIZATION_2_BIT = KINK_UTILIZATION_2_BYTE * 8;
    uint256 private constant MAX_RATE_BIT           = MAX_RATE_BYTE * 8;
    uint256 private constant KINK_RATE_1_BIT        = KINK_RATE_1_BYTE * 8;
    uint256 private constant KINK_RATE_2_BIT        = KINK_RATE_2_BYTE * 8;
    uint256 private constant MIN_FEE_RATE_BIT       = MIN_FEE_RATE_BYTE * 8;
    uint256 private constant MAX_FEE_RATE_BIT       = MAX_FEE_RATE_BYTE * 8;
    uint256 private constant FEE_RATE_PERCENT_BIT   = FEE_RATE_PERCENT_BYTE * 8;

    /// @notice Returns the marketIndex byte offset.
    /// @dev marketIndex = 0 is unused for fCash markets (they are 1-indexed). In the storage
    /// slot the marketIndex = 0 space is reserved for the prime cash borrow curve
    function _getMarketIndexOffset(uint256 marketIndex) private pure returns (uint8 offset) {
        require(0 < marketIndex);
        require(marketIndex <= Constants.MAX_TRADED_MARKET_INDEX);
        offset = uint8(marketIndex < 4 ? marketIndex : marketIndex - 4) * 8;
    }

    function _getfCashInterestRateParams(
        uint16 currencyId,
        uint256 marketIndex,
        mapping(uint256 => bytes32[2]) storage store
    ) private view returns (InterestRateParameters memory i) {
        uint8 offset = _getMarketIndexOffset(marketIndex);
        bytes32 data = store[currencyId][marketIndex < 4 ? 0 : 1];
        return unpackInterestRateParams(offset, data);
    }

    function unpackInterestRateParams(
        uint8 offset,
        bytes32 data
    ) internal pure returns (InterestRateParameters memory i) {
        // Kink utilization is stored as a value less than 100 and on the stack it is
        // in RATE_PRECISION where RATE_PRECISION = 100
        i.kinkUtilization1 = uint256(uint8(data[offset + KINK_UTILIZATION_1_BYTE])) * uint256(Constants.RATE_PRECISION)
            / uint256(Constants.PERCENTAGE_DECIMALS);
        i.kinkUtilization2 = uint256(uint8(data[offset + KINK_UTILIZATION_2_BYTE])) * uint256(Constants.RATE_PRECISION)
            / uint256(Constants.PERCENTAGE_DECIMALS);
        // Max Rate is stored in 25 basis point increments
        i.maxRate = uint256(uint8(data[offset + MAX_RATE_BYTE])) * 25 * uint256(Constants.BASIS_POINT);
        // Kink Rates are stored as 1/256 increments of maxRate, this allows governance
        // to set more precise kink rates relative to how how interest rates can go
        i.kinkRate1 = uint256(uint8(data[offset + KINK_RATE_1_BYTE])) * i.maxRate / 256;
        i.kinkRate2 = uint256(uint8(data[offset + KINK_RATE_2_BYTE])) * i.maxRate / 256;

        // Fee rates are stored in basis points
        i.minFeeRate = uint256(uint8(data[offset + MIN_FEE_RATE_BYTE])) * uint256(Constants.BASIS_POINT);
        i.maxFeeRate = uint256(uint8(data[offset + MAX_FEE_RATE_BYTE])) * uint256(Constants.BASIS_POINT);
        i.feeRatePercent = uint256(uint8(data[offset + FEE_RATE_PERCENT_BYTE]));
    }

    function packInterestRateParams(InterestRateCurveSettings memory settings) internal pure returns (bytes32) {
        require(settings.kinkUtilization1 < settings.kinkUtilization2);
        require(settings.kinkUtilization2 <= 100);
        require(settings.kinkRate1 < settings.kinkRate2);
        require(settings.minFeeRateBPS <= settings.maxFeeRateBPS);
        require(settings.feeRatePercent < 100);

        return (
            bytes32(uint256(settings.kinkUtilization1)) << 56 - KINK_UTILIZATION_1_BIT |
            bytes32(uint256(settings.kinkUtilization2)) << 56 - KINK_UTILIZATION_2_BIT |
            bytes32(uint256(settings.maxRate25BPS))     << 56 - MAX_RATE_BIT           |
            bytes32(uint256(settings.kinkRate1))        << 56 - KINK_RATE_1_BIT        |
            bytes32(uint256(settings.kinkRate2))        << 56 - KINK_RATE_2_BIT        |
            bytes32(uint256(settings.minFeeRateBPS))    << 56 - MIN_FEE_RATE_BIT       |
            bytes32(uint256(settings.maxFeeRateBPS))    << 56 - MAX_FEE_RATE_BIT       |
            bytes32(uint256(settings.feeRatePercent))   << 56 - FEE_RATE_PERCENT_BIT
        );
    }

    function _setInterestRateParameters(
        bytes32 data,
        uint8 offset,
        InterestRateCurveSettings memory settings
    ) internal pure returns (bytes32) {
        // Does checks against interest rate params inside
        bytes32 packedSettings = packInterestRateParams(settings);
        packedSettings = (packedSettings << offset);

        // Use the mask to clear the previous settings
        bytes32 mask = ~(bytes32(uint256(type(uint64).max)) << offset);
        return (data & mask) | packedSettings;
    }

    function setNextInterestRateParameters(
        uint16 currencyId,
        uint256 marketIndex,
        InterestRateCurveSettings memory settings
    ) internal {
        bytes32[2] storage nextStorage = LibStorage.getNextInterestRateParameters()[currencyId];
        // 256 - 64 bits puts the offset at 192 bits (64 bits is how wide each set of interest
        // rate parameters is)
        uint8 shift = PRIME_CASH_SHIFT - _getMarketIndexOffset(marketIndex) * 8;
        uint8 slot = marketIndex < 4 ? 0 : 1;

        nextStorage[slot] = _setInterestRateParameters(nextStorage[slot], shift, settings);
    }

    function getActiveInterestRateParameters(
        uint16 currencyId,
        uint256 marketIndex
    ) internal view returns (InterestRateParameters memory i) {
        return _getfCashInterestRateParams(
            currencyId,
            marketIndex,
            LibStorage.getActiveInterestRateParameters()
        );
    }

    function getNextInterestRateParameters(
        uint16 currencyId,
        uint256 marketIndex
    ) internal view returns (InterestRateParameters memory i) {
        return _getfCashInterestRateParams(
            currencyId,
            marketIndex,
            LibStorage.getNextInterestRateParameters()
        );
    }

    function getPrimeCashInterestRateParameters(
        uint16 currencyId
    ) internal view returns (InterestRateParameters memory i) {
        bytes32 data = LibStorage.getActiveInterestRateParameters()[currencyId][0];
        return unpackInterestRateParams(PRIME_CASH_OFFSET, data);
    }

    /// @notice Sets prime cash interest rate parameters, which are always in active storage
    /// at left most bytes8 slot. This corresponds to marketIndex = 0 which is unused by fCash
    /// markets.
    function setPrimeCashInterestRateParameters(
        uint16 currencyId,
        InterestRateCurveSettings memory settings
    ) internal {
        bytes32[2] storage activeStorage = LibStorage.getActiveInterestRateParameters()[currencyId];
        bytes32[2] storage nextStorage = LibStorage.getNextInterestRateParameters()[currencyId];
        // Set the settings in both active and next. On the next market roll the prime cash parameters
        // will be preserved
        activeStorage[0] = _setInterestRateParameters(activeStorage[0], PRIME_CASH_SHIFT, settings);
        nextStorage[0] = _setInterestRateParameters(nextStorage[0], PRIME_CASH_SHIFT, settings);
    }

    function setActiveInterestRateParameters(uint16 currencyId) internal {
        // Whenever we set the active interest rate parameters, we just copy the next
        // values into the active storage values.
        bytes32[2] storage nextStorage = LibStorage.getNextInterestRateParameters()[currencyId];
        bytes32[2] storage activeStorage = LibStorage.getActiveInterestRateParameters()[currencyId];
        activeStorage[0] = nextStorage[0];
        activeStorage[1] = nextStorage[1];
    }

    /// @notice Oracle rate protects against short term price manipulation. Time window will be set to a value
    /// on the order of minutes to hours. This is to protect fCash valuations from market manipulation. For example,
    /// a trader could use a flash loan to dump a large amount of cash into the market and depress interest rates.
    /// Since we value fCash in portfolios based on these rates, portfolio values will decrease and they may then
    /// be liquidated.
    ///
    /// Oracle rates are calculated when the values are loaded from storage.
    ///
    /// The oracle rate is a lagged weighted average over a short term price window. If we are past
    /// the short term window then we just set the rate to the lastImpliedRate, otherwise we take the
    /// weighted average:
    ///     lastInterestRatePreTrade * (currentTs - previousTs) / timeWindow +
    ///         oracleRatePrevious * (1 - (currentTs - previousTs) / timeWindow)
    function updateRateOracle(
        uint256 lastUpdateTime,
        uint256 lastInterestRate,
        uint256 oracleRate,
        uint256 rateOracleTimeWindow,
        uint256 blockTime
    ) internal pure returns (uint256 newOracleRate) {
        require(rateOracleTimeWindow > 0); // dev: update rate oracle, time window zero

        // This can occur when using a view function get to a market state in the past
        if (lastUpdateTime > blockTime) return lastInterestRate;

        uint256 timeDiff = blockTime.sub(lastUpdateTime);
        // If past the time window just return the lastInterestRate
        if (timeDiff > rateOracleTimeWindow) return lastInterestRate;

        // (currentTs - previousTs) / timeWindow
        uint256 lastTradeWeight = timeDiff.divInRatePrecision(rateOracleTimeWindow);

        // 1 - (currentTs - previousTs) / timeWindow
        uint256 oracleWeight = uint256(Constants.RATE_PRECISION).sub(lastTradeWeight);

        // lastInterestRatePreTrade * lastTradeWeight + oracleRatePrevious * oracleWeight
        newOracleRate =
            (lastInterestRate.mul(lastTradeWeight).add(oracleRate.mul(oracleWeight)))
                .div(uint256(Constants.RATE_PRECISION));
    }

    /// @notice Returns the utilization for an fCash market:
    /// (totalfCash +/- fCashToAccount) / (totalfCash + totalCash)
    function getfCashUtilization(
        int256 fCashToAccount,
        int256 totalfCash,
        int256 totalCashUnderlying
    ) internal pure returns (uint256 utilization) {
        require(totalfCash >= 0);
        require(totalCashUnderlying >= 0);
        utilization = totalfCash.subNoNeg(fCashToAccount)
            .divInRatePrecision(totalCashUnderlying.add(totalfCash))
            .toUint();
    }

    /// @notice Returns the preFeeInterestRate given interest rate parameters and utilization
    function getInterestRate(
        InterestRateParameters memory irParams,
        uint256 utilization
    ) internal pure returns (uint256 preFeeInterestRate) {
        // If this is not set, then assume that the rate parameters have not been initialized
        // and revert.
        require(irParams.maxRate > 0);
        // Do not allow trading past 100% utilization, revert for safety here to prevent
        // underflows, however in calculatefCashTrade we check this explicitly to prevent
        // a revert. nToken redemption relies on the behavior that calculateTrade returns 0
        // during an unsuccessful trade.
        require(utilization <= uint256(Constants.RATE_PRECISION));

        if (utilization <= irParams.kinkUtilization1) {
            // utilization * kinkRate1 / kinkUtilization1
            preFeeInterestRate = utilization
                .mul(irParams.kinkRate1)
                .div(irParams.kinkUtilization1);
        } else if (utilization <= irParams.kinkUtilization2) {
            // (utilization - kinkUtilization1) * (kinkRate2 - kinkRate1) 
            // ---------------------------------------------------------- + kinkRate1
            //            (kinkUtilization2 - kinkUtilization1)
            preFeeInterestRate = (utilization - irParams.kinkUtilization1) // underflow checked
                .mul(irParams.kinkRate2 - irParams.kinkRate1) // underflow checked by definition
                .div(irParams.kinkUtilization2 - irParams.kinkUtilization1) // underflow checked by definition
                .add(irParams.kinkRate1);
        } else {
            // (utilization - kinkUtilization2) * (maxRate - kinkRate2) 
            // ---------------------------------------------------------- + kinkRate2
            //                  (1 - kinkUtilization2)
            preFeeInterestRate = (utilization - irParams.kinkUtilization2) // underflow checked
                .mul(irParams.maxRate - irParams.kinkRate2) // underflow checked by definition
                .div(uint256(Constants.RATE_PRECISION) - irParams.kinkUtilization2) // underflow checked by definition
                .add(irParams.kinkRate2);
        }
    }

    /// @notice Calculates a market utilization via the interest rate, is the
    /// inverse of getInterestRate
    function getUtilizationFromInterestRate(
        InterestRateParameters memory irParams,
        uint256 interestRate
    ) internal pure returns (uint256 utilization) {
        // If this is not set, then assume that the rate parameters have not been initialized
        // and revert.
        require(irParams.maxRate > 0);

        if (interestRate <= irParams.kinkRate1) {
            // interestRate * kinkUtilization1 / kinkRate1
            utilization = interestRate
                .mul(irParams.kinkUtilization1)
                .div(irParams.kinkRate1);
        } else if (interestRate <= irParams.kinkRate2) {
            // (interestRate - kinkRate1) * (kinkUtilization2 - kinkUtilization1) 
            // ------------------------------------------------------------------   + kinkUtilization1
            //                  (kinkRate2 - kinkRate1)
            utilization = (interestRate - irParams.kinkRate1) // underflow checked
                .mul(irParams.kinkUtilization2 - irParams.kinkUtilization1) // underflow checked by definition
                .div(irParams.kinkRate2 - irParams.kinkRate1) // underflow checked by definition
                .add(irParams.kinkUtilization1);
        } else {
            // NOTE: in this else block, it is possible for interestRate > maxRate and therefore this
            // method will return a utilization greater than 100%. During initialize markets, if this condition
            // exists then the utilization will be marked down to the leverage threshold which is by definition
            // less than 100% utilization.

            // (interestRate - kinkRate2) * (1 - kinkUtilization2)
            // -----------------------------------------------------  + kinkUtilization2
            //                  (maxRate - kinkRate2)
            utilization = (interestRate - irParams.kinkRate2) // underflow checked
                .mul(uint256(Constants.RATE_PRECISION) - irParams.kinkUtilization2) // underflow checked by definition
                .div(irParams.maxRate - irParams.kinkRate2) // underflow checked by definition
                .add(irParams.kinkUtilization2);
        }
    }

    /// @notice Applies fees to an interest rate
    /// @param irParams contains the relevant fee parameters
    /// @param preFeeInterestRate the interest rate before the fee
    /// @param isBorrow if true, the fee increases the rate, else it decreases the rate
    /// @return postFeeInterestRate the interest rate with a fee applied, floored at zero
    function getPostFeeInterestRate(
        InterestRateParameters memory irParams,
        uint256 preFeeInterestRate,
        bool isBorrow
    ) internal pure returns (uint256 postFeeInterestRate) {
        uint256 feeRate = preFeeInterestRate.mul(irParams.feeRatePercent).div(uint256(Constants.PERCENTAGE_DECIMALS));
        if (feeRate < irParams.minFeeRate) feeRate = irParams.minFeeRate;
        if (feeRate > irParams.maxFeeRate) feeRate = irParams.maxFeeRate;

        if (isBorrow) {
            // Borrows increase the interest rate, it is ok for the feeRate to exceed the maxRate here.
            postFeeInterestRate = preFeeInterestRate.add(feeRate);
        } else {
            // Lending decreases the interest rate, do not allow the postFeeInterestRate to underflow
            postFeeInterestRate = feeRate > preFeeInterestRate ? 0 : (preFeeInterestRate - feeRate);
        }
    }

    /// @notice Calculates the asset cash amount the results from trading fCashToAccount with the market. A positive
    /// fCashToAccount is equivalent of lending, a negative is borrowing. Updates the market state in memory.
    /// @param market the current market state
    /// @param cashGroup cash group configuration parameters
    /// @param fCashToAccount the fCash amount that will be deposited into the user's portfolio. The net change
    /// to the market is in the opposite direction.
    /// @param timeToMaturity number of seconds until maturity
    /// @param marketIndex the relevant tenor of the market to trade on
    /// @return netAssetCash amount of asset cash to credit or debit to an account
    /// @return netAssetCashToReserve amount of cash to credit to the reserve (always positive)
    function calculatefCashTrade(
        MarketParameters memory market,
        CashGroupParameters memory cashGroup,
        int256 fCashToAccount,
        uint256 timeToMaturity,
        uint256 marketIndex
    ) internal view returns (int256, int256) {
        // Market index must be greater than zero
        require(marketIndex > 0);
        // We return false if there is not enough fCash to support this trade.
        // if fCashToAccount > 0 and totalfCash - fCashToAccount <= 0 then the trade will fail
        // if fCashToAccount < 0 and totalfCash > 0 then this will always pass
        if (market.totalfCash <= fCashToAccount) return (0, 0);

        InterestRateParameters memory irParams = getActiveInterestRateParameters(cashGroup.currencyId, marketIndex);
        int256 totalCashUnderlying = cashGroup.primeRate.convertToUnderlying(market.totalPrimeCash);

        // returns the net cash amounts to apply to each of the three relevant balances.
        (
            int256 netUnderlyingToAccount,
            int256 netUnderlyingToMarket,
            int256 netUnderlyingToReserve
        ) = _getNetCashAmountsUnderlying(
            irParams,
            market,
            cashGroup,
            totalCashUnderlying,
            fCashToAccount,
            timeToMaturity
        );

        // Signifies a failed net cash amount calculation
        if (netUnderlyingToAccount == 0) return (0, 0);

        {
            // Do not allow utilization to go above 100 on trading, calculate the utilization after
            // the trade has taken effect, meaning that fCash changes and cash changes are applied to
            // the market totals.
            market.totalfCash = market.totalfCash.subNoNeg(fCashToAccount);
            totalCashUnderlying = totalCashUnderlying.add(netUnderlyingToMarket);

            uint256 utilization = getfCashUtilization(0, market.totalfCash, totalCashUnderlying);
            if (utilization > uint256(Constants.RATE_PRECISION)) return (0, 0);

            uint256 newPreFeeImpliedRate = getInterestRate(irParams, utilization);

            // It's technically possible that the implied rate is actually exactly zero we will still
            // fail in this case. If this does happen we may assume that markets are not initialized.
            if (newPreFeeImpliedRate == 0) return (0, 0);

            // Saves the preFeeInterestRate and fCash
            market.lastImpliedRate = newPreFeeImpliedRate;
        }

        return _setNewMarketState(
            market,
            cashGroup.primeRate,
            netUnderlyingToAccount,
            netUnderlyingToMarket,
            netUnderlyingToReserve
        );
    }

    /// @notice Returns net underlying cash amounts to the account, the market and the reserve.
    /// @return postFeeCashToAccount this is a positive or negative amount of cash change to the account
    /// @return netUnderlyingToMarket this is a positive or negative amount of cash change in the market
    /// @return cashToReserve this is always a positive amount of cash accrued to the reserve
    function _getNetCashAmountsUnderlying(
        InterestRateParameters memory irParams,
        MarketParameters memory market,
        CashGroupParameters memory cashGroup,
        int256 totalCashUnderlying,
        int256 fCashToAccount,
        uint256 timeToMaturity
    ) private pure returns (int256 postFeeCashToAccount, int256 netUnderlyingToMarket, int256 cashToReserve) {
        uint256 utilization = getfCashUtilization(fCashToAccount, market.totalfCash, totalCashUnderlying);
        // Do not allow utilization to go above 100 on trading
        if (utilization > uint256(Constants.RATE_PRECISION)) return (0, 0, 0);
        uint256 preFeeInterestRate = getInterestRate(irParams, utilization);

        int256 preFeeCashToAccount = fCashToAccount.divInRatePrecision(
            getfCashExchangeRate(preFeeInterestRate, timeToMaturity)
        ).neg();

        uint256 postFeeInterestRate = getPostFeeInterestRate(irParams, preFeeInterestRate, fCashToAccount < 0);
        postFeeCashToAccount = fCashToAccount.divInRatePrecision(
            getfCashExchangeRate(postFeeInterestRate, timeToMaturity)
        ).neg();

        require(postFeeCashToAccount <= preFeeCashToAccount);
        // Both pre fee cash to account and post fee cash to account are either negative (lending) or positive
        // (borrowing). Fee will be positive or zero as a result.
        int256 fee = preFeeCashToAccount.sub(postFeeCashToAccount);

        cashToReserve = fee.mul(cashGroup.getReserveFeeShare()).div(Constants.PERCENTAGE_DECIMALS);

        // This inequality must hold inside given the fees:
        //  netToMarket + cashToReserve + postFeeCashToAccount = 0

        // Example: Lending
        // Pre Fee Cash: -97 ETH
        // Post Fee Cash: -100 ETH
        // Fee: 3 ETH
        // To Reserve: 1 ETH
        // Net To Market = 99 ETH
        // 99 + 1 - 100 == 0

        // Example: Borrowing
        // Pre Fee Cash: 100 ETH
        // Post Fee Cash: 97 ETH
        // Fee: 3 ETH
        // To Reserve: 1 ETH
        // Net To Market = -98 ETH
        // 97 + 1 - 98 == 0

        // Therefore:
        //  netToMarket = - cashToReserve - postFeeCashToAccount
        //  netToMarket = - (cashToReserve + postFeeCashToAccount)

        netUnderlyingToMarket = (postFeeCashToAccount.add(cashToReserve)).neg();
    }

    /// @notice Sets the new market state
    /// @return netAssetCashToAccount: the positive or negative change in asset cash to the account
    /// @return assetCashToReserve: the positive amount of cash that accrues to the reserve
    function _setNewMarketState(
        MarketParameters memory market,
        PrimeRate memory primeRate,
        int256 netUnderlyingToAccount,
        int256 netUnderlyingToMarket,
        int256 netUnderlyingToReserve
    ) private view returns (int256, int256) {
        int256 netPrimeCashToMarket = primeRate.convertFromUnderlying(netUnderlyingToMarket);
        // Set storage checks that total prime cash is above zero
        market.totalPrimeCash = market.totalPrimeCash.add(netPrimeCashToMarket);

        // Sets the trade time for the next oracle update
        market.previousTradeTime = block.timestamp;
        int256 primeCashToReserve = primeRate.convertFromUnderlying(netUnderlyingToReserve);
        int256 netPrimeCashToAccount = primeRate.convertFromUnderlying(netUnderlyingToAccount);
        return (netPrimeCashToAccount, primeCashToReserve);
    }

    /// @notice Converts an interest rate to an exchange rate given a time to maturity. The
    /// formula is E = e^rt
    function getfCashExchangeRate(
        uint256 interestRate,
        uint256 timeToMaturity
    ) internal pure returns (int256 exchangeRate) {
        int128 expValue =
            ABDKMath64x64.fromUInt(interestRate.mul(timeToMaturity).div(Constants.YEAR));
        int128 expValueScaled = ABDKMath64x64.div(expValue, Constants.RATE_PRECISION_64x64);
        int128 expResult = ABDKMath64x64.exp(expValueScaled);
        int128 expResultScaled = ABDKMath64x64.mul(expResult, Constants.RATE_PRECISION_64x64);

        exchangeRate = ABDKMath64x64.toInt(expResultScaled);
    }

    /// @notice Uses secant method to converge on an fCash amount given the amount
    /// of cash. The relation between cash and fCash is:
    /// f(fCash) = cashAmount * exchangeRatePostFee(fCash) + fCash = 0
    /// where exchangeRatePostFee = e ^ (interestRatePostFee * timeToMaturity)
    ///       and interestRatePostFee = interestRateFunc(utilization)
    ///       and utilization = (totalfCash - fCashToAccount) / (totalfCash + totalCash)
    ///
    /// interestRateFunc is guaranteed to be monotonic and continuous, however, it is not
    /// differentiable therefore we must use the secant method instead of Newton's method.
    ///
    /// Secant method is:
    ///                          x_1 - x_0
    ///  x_n = x_1 - f(x_1) * ---------------
    ///                       f(x_1) - f(x_0)
    ///
    ///  break when (x_n - x_1) < maxDelta
    ///
    /// The initial guesses for x_0 and x_1 depend on the direction of the trade.
    ///     netUnderlyingToAccount > 0, then fCashToAccount < 0 and the interest rate will increase
    ///         therefore x_0 = f @ current utilization and x_1 = f @ max utilization
    ///     netUnderlyingToAccount < 0, then fCashToAccount > 0 and the interest rate will decrease
    ///         therefore x_0 = f @ min utilization and x_1 = f @ current utilization
    ///
    /// These initial guesses will ensure that the method converges to a root (if one exists).
    function getfCashGivenCashAmount(
        InterestRateParameters memory irParams,
        int256 totalfCash,
        int256 netUnderlyingToAccount,
        int256 totalCashUnderlying,
        uint256 timeToMaturity
    ) internal pure returns (int256) {
        require(netUnderlyingToAccount != 0);
        // Cannot borrow more than total cash underlying
        require(netUnderlyingToAccount <= totalCashUnderlying, "Over Market Limit");

        int256 fCash_0;
        int256 fCash_1;
        {
            // Calculate fCash rate at the current mid point
            int256 currentfCashExchangeRate = _calculatePostFeeExchangeRate(
                irParams,
                totalfCash,
                totalCashUnderlying,
                timeToMaturity,
                netUnderlyingToAccount > 0 ? int256(-1) : int256(1) // set this such that we get the correct fee direction
            );

            if (netUnderlyingToAccount < 0) {
                // Lending
                // Minimum guess is lending at 0% interest, which means receiving fCash 1-1
                // with underlying cash amounts
                fCash_0 = netUnderlyingToAccount.neg();
                fCash_1 = netUnderlyingToAccount.mulInRatePrecision(currentfCashExchangeRate).neg();
            } else {
                // Borrowing
                fCash_0 = netUnderlyingToAccount.mulInRatePrecision(currentfCashExchangeRate).neg();
                fCash_1 = netUnderlyingToAccount.mulInRatePrecision(
                    getfCashExchangeRate(irParams.maxRate, timeToMaturity)
                ).neg();
            }
        }

        int256 diff_0 = _calculateDiff(
            irParams,
            totalfCash,
            totalCashUnderlying,
            fCash_0,
            timeToMaturity,
            netUnderlyingToAccount
        );

        for (uint8 i = 0; i < 250; i++) {
            int256 fCashDelta = (fCash_1 - fCash_0);
            if (fCashDelta == 0) return fCash_1;
            int256 diff_1 = _calculateDiff(
                irParams,
                totalfCash,
                totalCashUnderlying,
                fCash_1,
                timeToMaturity,
                netUnderlyingToAccount
            );
            int256 fCash_n = fCash_1.sub(diff_1.mul(fCashDelta).div(diff_1.sub(diff_0)));

            // Assign new values for next comparison
            (fCash_1, fCash_0) = (fCash_n, fCash_1);
            diff_0 = diff_1;
        }

        revert("No convergence");
    }

    function _calculateDiff(
        InterestRateParameters memory irParams,
        int256 totalfCash,
        int256 totalCashUnderlying,
        int256 fCashToAccount,
        uint256 timeToMaturity,
        int256 netUnderlyingToAccount
    ) private pure returns (int256) {
        int256 exchangeRate =  _calculatePostFeeExchangeRate(
            irParams,
            totalfCash,
            totalCashUnderlying,
            timeToMaturity,
            fCashToAccount
        );

        return fCashToAccount.add(netUnderlyingToAccount.mulInRatePrecision(exchangeRate));
    }

    function _calculatePostFeeExchangeRate(
        InterestRateParameters memory irParams,
        int256 totalfCash,
        int256 totalCashUnderlying,
        uint256 timeToMaturity,
        int256 fCashToAccount
    ) private pure returns (int256) {
        uint256 preFeeInterestRate = getInterestRate(
            irParams,
            getfCashUtilization(fCashToAccount, totalfCash, totalCashUnderlying)
        );
        uint256 postFeeInterestRate = getPostFeeInterestRate(irParams, preFeeInterestRate, fCashToAccount < 0);

        return getfCashExchangeRate(postFeeInterestRate, timeToMaturity);
    }
}
