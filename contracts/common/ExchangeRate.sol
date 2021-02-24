// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "../storage/StorageLayoutV1.sol";
import "../storage/TokenHandler.sol";
import "interfaces/chainlink/AggregatorV2V3Interface.sol";

/**
 * @dev Exchange rate object as stored in memory, these are cached optimistically
 * when the transaction begins. This is not the same as the object in storage.
 */ 
struct ETHRate {
    // The decimals (i.e. 10^rateDecimalPlaces) of the exchange rate
    int rateDecimals;
    // The exchange rate from base to quote (if invert is required it is already done)
    int rate;
    // Amount of buffer to apply to the exchange rate for negative balances.
    int buffer;
    // Amount of haircut to apply to the exchange rate for positive balances
    int haircut;
    // Liquidation discount for this currency
    int liquidationDiscount;
}

/**
 * @title ExchangeRate
 * @notice Internal library for calculating exchange rates between different currencies
 * and assets. Must be supplied a Rate struct with relevant parameters. Expects rate oracles
 * to conform to the Chainlink AggregatorV2V3Interface. 
 *
 * This is used on internal balances which are all denominated in 1e9 precision.
 */
library ExchangeRate {
    using SafeInt256 for int256;

    // ETH occupies the first currency
    uint internal constant ETH = 1;
    uint internal constant ETH_RATE_STORAGE_SLOT = 2;
    int public constant MULTIPLIER_DECIMALS = 100;
    int public constant ETH_DECIMALS = 1e18;

    /**
     * @notice Converts a balance to ETH from a base currency. Buffers or haircuts are
     * always applied in this method.
     *
     * @param er exchange rate object from base to ETH
     * @return the converted balance denominated in ETH with TokenHandler.INTERNAL_TOKEN_PRECISION
     */
    function convertToETH(
        ETHRate memory er,
        int balance
    ) internal pure returns (int) {
        if (balance == 0) return 0;
        int multiplier = balance > 0 ? er.haircut : er.buffer;

        // We are converting internal balances here so we know they have INTERNAL_TOKEN_PRECISION decimals
        // internalDecimals * rateDecimals * multiplier /  (rateDecimals * multiplierDecimals)
        // Therefore the result is in ethDecimals
        int result = balance
            .mul(er.rate)
            .mul(multiplier)
            .div(MULTIPLIER_DECIMALS)
            .div(er.rateDecimals);

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
        ETHRate memory er,
        int balance
    ) internal pure returns (int) {
        if (balance == 0) return 0;

        // We are converting internal balances here so we know they have INTERNAL_TOKEN_PRECISION decimals
        // internalDecimals * rateDecimals / rateDecimala
        int result = balance
            .mul(er.rateDecimals)
            .div(er.rate);

        return result;
    }

    /**
     * @notice Calculates the exchange rate between two currencies via ETH. Returns the rate denominated in
     * base exchange rate decimals: (baseRateDecimals * quoteRateDecimals) / quoteRateDecimals
     *
     * @param baseER base exchange rate struct
     * @param quoteER quote exchange rate struct
     */
    function exchangeRate(ETHRate memory baseER, ETHRate memory quoteER) internal pure returns (int) {
        return baseER.rate.mul(quoteER.rateDecimals).div(quoteER.rate);
    }

    /**
     * @notice Returns an ETHRate object used to calculate free collateral
     */
    function buildExchangeRate(
        uint currencyId
    ) internal view returns (ETHRate memory) {
        bytes32 slot = keccak256(abi.encode(currencyId, ETH_RATE_STORAGE_SLOT));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        int rateDecimals;
        int rate;
        if (currencyId == ETH) {
            // ETH rates will just be 1e18, but will still have buffers, haircuts,
            // and liquidation discounts
            rateDecimals = ETH_DECIMALS;
            rate = ETH_DECIMALS;
        } else {
            address rateOracle = address(bytes20(data << 96));
            (
                /* uint80 */,
                rate,
                /* uint256 */,
                /* uint256 */,
                /* uint80 */
            ) = AggregatorV2V3Interface(rateOracle).latestRoundData();
            require(rate > 0, "ExchangeRate: invalid rate");

            uint8 rateDecimalPlaces = uint8(bytes1(data << 88));
            rateDecimals = int(10**rateDecimalPlaces);
            if (bytes1(data << 80) != 0x00 /* mustInvert */) rate = rateDecimals.mul(rateDecimals).div(rate);
        }

        int buffer = int(uint8(bytes1(data << 72)));
        int haircut = int(uint8(bytes1(data << 64)));
        int liquidationDiscount = int(uint8(bytes1(data << 56)));

        return ETHRate({
            rateDecimals: rateDecimals,
            rate: rate,
            buffer: buffer,
            haircut: haircut,
            liquidationDiscount: liquidationDiscount
        });
    }
}