// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../balances/TokenHandler.sol";
import "../../math/SafeInt256.sol";
import "../../../interfaces/chainlink/AggregatorV2V3Interface.sol";

library ExchangeRate {
    using SafeInt256 for int256;

    /// @notice Converts a balance to ETH from a base currency. Buffers or haircuts are
    /// always applied in this method.
    /// @param er exchange rate object from base to ETH
    /// @return the converted balance denominated in ETH with Constants.INTERNAL_TOKEN_PRECISION
    function convertToETH(ETHRate memory er, int256 balance) internal pure returns (int256) {
        int256 multiplier = balance > 0 ? er.haircut : er.buffer;

        // We are converting internal balances here so we know they have INTERNAL_TOKEN_PRECISION decimals
        // internalDecimals * rateDecimals * multiplier /  (rateDecimals * multiplierDecimals)
        // Therefore the result is in ethDecimals
        int256 result =
            balance.mul(er.rate).mul(multiplier).div(Constants.PERCENTAGE_DECIMALS).div(
                er.rateDecimals
            );

        return result;
    }

    /// @notice Converts the balance denominated in ETH to the equivalent value in a base currency.
    /// Buffers and haircuts ARE NOT applied in this method.
    /// @param er exchange rate object from base to ETH
    /// @param balance amount (denominated in ETH) to convert
    function convertETHTo(ETHRate memory er, int256 balance) internal pure returns (int256) {
        // We are converting internal balances here so we know they have INTERNAL_TOKEN_PRECISION decimals
        // internalDecimals * rateDecimals / rateDecimals
        int256 result = balance.mul(er.rateDecimals).div(er.rate);

        return result;
    }

    /// @notice Calculates the exchange rate between two currencies via ETH. Returns the rate denominated in
    /// base exchange rate decimals: (baseRateDecimals * quoteRateDecimals) / quoteRateDecimals
    /// @param baseER base exchange rate struct
    /// @param quoteER quote exchange rate struct
    function exchangeRate(ETHRate memory baseER, ETHRate memory quoteER)
        internal
        pure
        returns (int256)
    {
        return baseER.rate.mul(quoteER.rateDecimals).div(quoteER.rate);
    }

    /// @notice Returns an ETHRate object used to calculate free collateral
    function buildExchangeRate(uint256 currencyId) internal view returns (ETHRate memory) {
        mapping(uint256 => ETHRateStorage) storage store = LibStorage.getExchangeRateStorage();
        ETHRateStorage storage ethStorage = store[currencyId];

        int256 rateDecimals;
        int256 rate;
        if (currencyId == Constants.ETH_CURRENCY_ID) {
            // ETH rates will just be 1e18, but will still have buffers, haircuts,
            // and liquidation discounts
            rateDecimals = Constants.ETH_DECIMALS;
            rate = Constants.ETH_DECIMALS;
        } else {
            // prettier-ignore
            (
                /* roundId */,
                rate,
                /* uint256 startedAt */,
                /* updatedAt */,
                /* answeredInRound */
            ) = ethStorage.rateOracle.latestRoundData();
            require(rate > 0, "Invalid rate");

            // No overflow, restricted on storage
            rateDecimals = int256(10**ethStorage.rateDecimalPlaces);
            if (ethStorage.mustInvert) {
                rate = rateDecimals.mul(rateDecimals).div(rate);
            }
        }

        return
            ETHRate({
                rateDecimals: rateDecimals,
                rate: rate,
                buffer: ethStorage.buffer,
                haircut: ethStorage.haircut,
                liquidationDiscount: ethStorage.liquidationDiscount
            });
    }
}
