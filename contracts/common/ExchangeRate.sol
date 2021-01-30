// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "../storage/StorageLayoutV1.sol";
import "./Market.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "interfaces/chainlink/AggregatorV2V3Interface.sol";


/**
 * @dev Exchange rate object as stored in memory, these are cached optimistically
 * when the transaction begins. This is not the same as the object in storage.
 */ 
struct Rate {
    // The decimals (i.e. 10^rateDecimalPlaces) of the exchange rate
    int rateDecimals;
    // The decimals (i.e. 10^baseDecimals) of the base currency
    int baseDecimals;
    // The decimals (i.e. 10^quoteDecimals) of the quote currency
    int quoteDecimals;
    // The exchange rate from base to quote (if invert is required it is already done)
    int rate;
    // Amount of buffer to apply to the exchange rate for negative balances.
    int buffer;
    // Amount of haircut to apply to the exchange rate for positive balances
    int haircut;
}

/**
 * @title ExchangeRate
 * @notice Internal library for calculating exchange rates between different currencies
 * and assets. Must be supplied a Rate struct with relevant parameters. Expects rate oracles
 * to conform to the Chainlink AggregatorV2V3Interface.
 */
library ExchangeRate {
    using SafeInt256 for int256;
    using SafeMath for uint256;

    int public constant MULTIPLIER_DECIMALS = 100;
    int public constant ETH_DECIMALS = 1e18;

    /**
     * @notice Converts a balance to ETH from a base currency. Buffers or haircuts are
     * always applied in this method.
     *
     * @param er exchange rate object from base to ETH
     * @return the converted balance denominated in ETH with 18 decimal places
     */
    function convertToETH(
        Rate memory er,
        int balance
    ) internal pure returns (int) {
        if (balance == 0) return 0;
        int multiplier = balance > 0 ? er.haircut : er.buffer;

        // We are converting to ETH here so we know that it has 1e18 precision. The calculation here is:
        // baseDecimals * rateDecimals * multiplier * ethDecimals /  (rateDecimals * baseDecimals * multiplierDecimals)
        // Therefore the result is in ethDecimals
        int result = balance
            .mul(er.rate)
            .mul(multiplier)
            .mul(ETH_DECIMALS)
            .div(MULTIPLIER_DECIMALS)
            .div(er.rateDecimals)
            .div(er.baseDecimals);

        return result;
    }

    /**
     * @notice Converts the balance denominated in ETH to the equivalent value in a base currency.
     * Buffers and haircuts ARE NOT applied in this method.
     *
     * @param er exchange rate object from base to ETH
     * @param balance amount (denominated in ETH) to convert
     */
    function convertETHTo(
        Rate memory er,
        int balance
    ) internal pure returns (int) {
        if (balance == 0) return 0;

        // We are converting from ETH here so we know that it has 1e18 precision. The calculation here is:
        // ethDecimals * rateDecimals * baseDecimals / (ethDecimals * rateDecimals)
        int result = balance
            .mul(er.rateDecimals)
            .mul(er.baseDecimals)
            .div(er.rate)
            .div(ETH_DECIMALS);

        return result;
    }

    /**
     * @notice Converts an internal asset value to its underlying token value. Internally, cash and fCash are all specified
     * at Market.RATE_PRECISION so no decimal conversion is necessary here. Conversion is only required when transferring
     * externally from the system.
     *
     * Buffers and haircuts ARE NOT applied here. Asset rates are defined as assetRate * assetBalance = underlyingBalance.
     * Underlying is referred to as the quote currency in these exchange rates. Asset is referred to as the base currency
     * in these exchange rates.
     *
     * @param er exchange rate object between asset and underlying
     * @param assetBalance amount (denominated in asset value) to convert to underlying
     */
    function convertInternalToUnderlying(
        Rate memory er,
        int assetBalance
    ) internal pure returns (int) {
        if (assetBalance == 0) return 0;

        // Calculation here represents:
        // rateDecimals * balance / rateDecimals
        int underlyingBalance = er.rate
            .mul(assetBalance)
            .div(er.rateDecimals);

        return underlyingBalance;
    }

    /**
     * @notice Converts an internal asset value to its underlying token value. Internally, cash and fCash are all specified
     * at Market.RATE_PRECISION so no decimal conversion is necessary here. Conversion is only required when transferring
     * externally from the system.
     *
     * Buffers and haircuts ARE NOT applied here. Asset rates are defined as assetRate * assetBalance =
     * underlyingBalance. Underlying is referred to as the quote currency in these exchange rates.
     *
     * @param er exchange rate object between asset and underlying
     * @param underlyingBalance amount (denominated in underlying value) to convert to asset value
     */
    function convertInternalFromUnderlying(
        Rate memory er,
        int underlyingBalance
    ) internal pure returns (int) {
        if (underlyingBalance == 0) return 0;

        // Calculation here represents:
        // rateDecimals * balance / rateDecimals
        int assetBalance = underlyingBalance
            .mul(er.rateDecimals)
            .div(er.rate);

        return assetBalance;
    }

    /**
     * @notice Calculates the exchange rate between two currencies via ETH. Returns the rate.
     *
     * @param baseER base exchange rate struct
     * @param quoteER quote exchange rate struct
     */
    function exchangeRate(Rate memory baseER, Rate memory quoteER) internal pure returns (int) {
        return baseER.rate.mul(quoteER.rateDecimals).div(quoteER.rate);
    }

    /**
     * @notice Given an exchange rate storage object, returns the in-memory exchange rate object
     * that will be used in contract calculations.
     *
     * @param rateStorage rate storage object
     */
    function buildExchangeRate(
        RateStorage memory rateStorage
    ) internal view returns (Rate memory) {
        (
            /* uint80 */,
            int rate,
            /* uint256 */,
            /* uint256 */,
            /* uint80 */
        ) = AggregatorV2V3Interface(rateStorage.rateOracle).latestRoundData();
        require(rate > 0, "ExchangeRate: invalid rate");
        int rateDecimals = int(10**rateStorage.rateDecimalPlaces);
        if (rateStorage.mustInvert) rate = rateDecimals.mul(rateDecimals).div(rate);

        int baseDecimals = int(10**rateStorage.baseDecimalPlaces);
        // If quoteDecimalPlaces is supplied as zero then we set this to zero
        int quoteDecimals = rateStorage.quoteDecimalPlaces == 0 ?
            0 : int(10**rateStorage.quoteDecimalPlaces);

        return Rate({
            rateDecimals: rateDecimals,
            baseDecimals: baseDecimals,
            quoteDecimals: quoteDecimals,
            rate: rate,
            buffer: rateStorage.buffer,
            haircut: rateStorage.haircut
        });
    }

    function buildSettlementRate(
        int settlementRate,
        uint rateDecimalPlaces
    ) internal pure returns (Rate memory) {
        int rateDecimals = int(10**rateDecimalPlaces);

        return Rate({
            rateDecimals: rateDecimals,
            baseDecimals: 0,
            quoteDecimals: 0,
            rate: settlementRate,
            buffer: 0,
            haircut: 0
        });
    }

}


contract MockExchangeRate {
    using SafeInt256 for int256;
    using ExchangeRate for Rate;

    function assertBalanceSign(int balance, int result) private pure {
        if (balance == 0) assert(result == 0);
        else if (balance < 0) assert(result < 0);
        else if (balance > 0) assert(result > 0);
    }

    // Prove that exchange rates move in the correct direction
    function assertRateDirection(
        int base,
        int quote,
        int baseDecimals,
        int quoteDecimals,
        Rate memory er
    ) private pure {
        require(er.rate > 0);
        require(baseDecimals > 0);
        require(quoteDecimals > 0);

        if (base == 0) return;

        int baseInQuoteDecimals = base.mul(quoteDecimals).div(baseDecimals).abs();
        int quoteAbs = quote.abs();
        if (er.rate == er.rateDecimals) {
            assert(quoteAbs == baseInQuoteDecimals);
        } else if (er.rate < er.rateDecimals) {
            assert(quoteAbs < baseInQuoteDecimals);
        } else if (er.rate > er.rateDecimals) {
            assert(quoteAbs > baseInQuoteDecimals);
        }
    }

    function convertToETH(
        Rate memory er,
        int balance
    ) external pure returns (int) {
        require(er.rate > 0);
        int result = er.convertToETH(balance);
        assertBalanceSign(balance, result);

        return result;
    }

    function convertETHTo(
        Rate memory er,
        int balance
    ) external pure returns (int) {
        require(er.rate > 0);
        int result = er.convertETHTo(balance);
        assertBalanceSign(balance, result);
        assertRateDirection(result, balance, er.baseDecimals, 1e18, er);

        return result;
    }

    function convertInternalToUnderlying(
        Rate memory er,
        int balance
    ) external pure returns (int) {
        require(er.rate > 0);
        int result = er.convertInternalToUnderlying(balance);
        assertBalanceSign(balance, result);
        assertRateDirection(balance, result, Market.RATE_PRECISION, Market.RATE_PRECISION, er);

        return result;
    }

    function convertInternalFromUnderlying(
        Rate memory er,
        int balance
    ) external pure returns (int) {
        require(er.rate > 0);
        int result = er.convertInternalFromUnderlying(balance);
        assertBalanceSign(balance, result);
        assertRateDirection(result, balance, Market.RATE_PRECISION, Market.RATE_PRECISION, er);

        return result;
    }

    function exchangeRate(
        Rate memory baseER,
        Rate memory quoteER
    ) external pure returns (int) {
        require(baseER.rate > 0);
        require(quoteER.rate > 0);

        int result = baseER.exchangeRate(quoteER);
        assert(result > 0);

        return result;
    }

    function buildExchangeRate(
        RateStorage memory rateStorage
    ) external view returns (Rate memory) {
        return ExchangeRate.buildExchangeRate(rateStorage);
    }


}