// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "../storage/StorageLayoutV1.sol";
import "interfaces/chainlink/AggregatorV2V3Interface.sol";

/**
 * @dev Exchange rate object as stored in memory, these are cached optimistically
 * when the transaction begins. This is not the same as the object in storage.
 */ 
struct ETHRate {
    // The decimals (i.e. 10^rateDecimalPlaces) of the exchange rate
    int rateDecimals;
    // The decimals (i.e. 10^baseDecimals) of the base currency
    int baseDecimals;
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

    uint internal constant ETH_RATE_STORAGE_SLOT = 2;
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
        ETHRate memory er,
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
        ETHRate memory er,
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
     * @notice Calculates the exchange rate between two currencies via ETH. Returns the rate.
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

        address rateOracle = address(bytes20(data << 96));
        (
            /* uint80 */,
            int rate,
            /* uint256 */,
            /* uint256 */,
            /* uint80 */
        ) = AggregatorV2V3Interface(rateOracle).latestRoundData();
        require(rate > 0, "ExchangeRate: invalid rate");

        uint8 rateDecimalPlaces = uint8(bytes1(data << 88));
        int rateDecimals = int(10**rateDecimalPlaces);
        if (bytes1(data << 80) != 0x00 /* mustInvert */) rate = rateDecimals.mul(rateDecimals).div(rate);

        int buffer = int(uint8(bytes1(data << 72)));
        int haircut = int(uint8(bytes1(data << 64)));
        int baseDecimals = int(10**uint8(bytes1(data << 48)));

        return ETHRate({
            rateDecimals: rateDecimals,
            baseDecimals: baseDecimals,
            rate: rate,
            buffer: buffer,
            haircut: haircut
        });
    }
}


contract MockExchangeRate is StorageLayoutV1 {
    using SafeInt256 for int256;
    using ExchangeRate for ETHRate;

    function setETHRateMapping(
        uint id,
        RateStorage calldata rs
    ) external {
        underlyingToETHRateMapping[id] = rs;
    }

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
        ETHRate memory er
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
        ETHRate memory er,
        int balance
    ) external pure returns (int) {
        require(er.rate > 0);
        int result = er.convertToETH(balance);
        assertBalanceSign(balance, result);

        return result;
    }

    function convertETHTo(
        ETHRate memory er,
        int balance
    ) external pure returns (int) {
        require(er.rate > 0);
        int result = er.convertETHTo(balance);
        assertBalanceSign(balance, result);
        assertRateDirection(result, balance, er.baseDecimals, 1e18, er);

        return result;
    }

    function exchangeRate(
        ETHRate memory baseER,
        ETHRate memory quoteER
    ) external pure returns (int) {
        require(baseER.rate > 0);
        require(quoteER.rate > 0);

        int result = baseER.exchangeRate(quoteER);
        assert(result > 0);

        return result;
    }

    function buildExchangeRate(
        uint currencyId
    ) external view returns (ETHRate memory) {
        return ExchangeRate.buildExchangeRate(currencyId);
    }

}