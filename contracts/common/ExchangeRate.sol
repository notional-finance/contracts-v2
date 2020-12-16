// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "interfaces/chainlink/AggregatorV2V3Interface.sol";

library ExchangeRate {
    using SafeInt256 for int256;
    using SafeMath for uint256;

    uint internal constant BUFFER_DECIMALS = 1e9;
    uint internal constant ETH_DECIMALS = 1e18;

    /** Exchange rates between currencies */
    struct Rate {
        // The address of the chainlink price oracle
        address rateOracle;
        // The decimal places of precision that the rate oracle uses
        uint8 rateDecimalsPlaces;
        // True of the exchange rate must be inverted
        bool mustInvert;
        // Amount of buffer to apply to the exchange rate, this defines the collateralization ratio
        // between the two currencies. This must be stored with 9 decimal places of precision
        uint32 buffer;
    }

    /**
     * @notice Converts a balance between token addresses.
     *
     * @param er exchange rate object from base to ETH
     * @param baseDecimals decimals for base currency
     * @param balance amount to convert
     * @return the converted balance denominated in ETH with 18 decimal places
     */
    function _convertToETH(
        Rate memory er,
        uint baseDecimals,
        int balance,
        bool buffer
    ) internal view returns (int) {
        // Fetches the latest answer from the chainlink oracle and buffer it by the apporpriate amount.
        uint rate = _fetchExchangeRate(er, false);
        uint absBalance = uint(balance.abs());
        uint rateDecimals = 10**er.rateDecimalsPlaces;
        uint bufferFactor = buffer ? uint(er.buffer).mul(BUFFER_DECIMALS) : ETH_DECIMALS;

        // We are converting to ETH here so we know that it has 1e18 precision. The calculation here is:
        // baseDecimals * rateDecimals * bufferDecimals * bufferDecimals /  (rateDecimals * baseDecimals)
        // er.buffer is in Common.DECIMAL precision
        // We use uint256 to do the calculation and then cast back to int256 to avoid overflows.
        int result = int(
            SafeCast.toUint128(rate
                .mul(absBalance)
                // Buffer has 9 decimal places of precision
                .mul(bufferFactor)
                .div(rateDecimals)
                .div(baseDecimals)
            )
        );

        return balance > 0 ? result : result.neg();
    }

    /**
     * @notice Converts the balance denominated in ETH to the equivalent value in base.
     * @param er exchange rate object from base to ETH
     * @param baseDecimals decimals for base currency
     * @param balance amount (denominated in ETH) to convert
     */
    function _convertETHTo(
        Rate memory er,
        uint baseDecimals,
        int balance
    ) internal view returns (int) {
        uint rate = _fetchExchangeRate(er, true);
        uint absBalance = uint(balance.abs());
        uint rateDecimals = 10**er.rateDecimalsPlaces;

        // We are converting from ETH here so we know that it has 1e18 precision. The calculation here is:
        // ethDecimals * rateDecimals * baseDecimals / (ethDecimals * rateDecimals)
        // er.buffer is in Common.DECIMAL precision
        // We use uint256 to do the calculation and then cast back to int256 to avoid overflows.
        int result = int(
            SafeCast.toUint128(rate
                .mul(absBalance)
                .mul(baseDecimals)
                .div(ETH_DECIMALS)
                .div(rateDecimals)
            )
        );

        return balance > 0 ? result : result.neg();
    }

    function _fetchExchangeRate(Rate memory er, bool invert) internal view returns (uint) {
        (
            /* uint80 */,
            int rate,
            /* uint256 */,
            /* uint256 */,
            /* uint80 */
        ) = AggregatorV2V3Interface(er.rateOracle).latestRoundData();
        require(rate > 0, "ExchangeRate: invalid rate");
        uint rateDecimals = 10**er.rateDecimalsPlaces;

        if (invert || (er.mustInvert && !invert)) {
            // If the ER is inverted and we're NOT asking to invert then we need to invert the rate here.
            return rateDecimals.mul(rateDecimals).div(uint(rate));
        }

        return uint(rate);
    }

    /**
     * @notice Calculates the exchange rate between two currencies via ETH. Returns the rate.
     */
    function _exchangeRate(Rate memory baseER, Rate memory quoteER, uint16 quote) internal view returns (uint) {
        uint rate = _fetchExchangeRate(baseER, false);

        if (quote != 0) {
            uint quoteRate = _fetchExchangeRate(quoteER, false);
            uint rateDecimals = 10**quoteER.rateDecimalsPlaces;

            rate = rate.mul(rateDecimals).div(quoteRate);
        }

        return rate;
    }

}


contract MockExchangeRate {

    function convertToETH(
        ExchangeRate.Rate memory er,
        uint256 baseDecimals,
        int256 balance,
        bool buffer
    ) external view returns (int) {
        return ExchangeRate._convertToETH(er, baseDecimals, balance, buffer);
    }

    function convertETHTo(
        ExchangeRate.Rate memory er,
        uint baseDecimals,
        int balance
    ) external view returns (int) {
        return ExchangeRate._convertETHTo(er, baseDecimals, balance);
    }

    function fetchExchangeRate(
        ExchangeRate.Rate memory er,
        bool invert
    ) external view returns (uint) {
        return ExchangeRate._fetchExchangeRate(er, invert);
    }

    function exchangeRate(
        ExchangeRate.Rate memory baseER,
        ExchangeRate.Rate memory quoteER,
        uint16 quote
    ) external view returns (uint256) {
        return ExchangeRate._exchangeRate(baseER, quoteER, quote);
    }

}