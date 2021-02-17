// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/ExchangeRate.sol";
import "../storage/StorageLayoutV1.sol";

contract MockExchangeRate is StorageLayoutV1 {
    using SafeInt256 for int256;
    using ExchangeRate for ETHRate;

    function setETHRateMapping(
        uint id,
        ETHRateStorage calldata rs
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
        ETHRate memory er
    ) private pure {
        require(er.rate > 0);
        if (base == 0) return;

        if (er.rate == er.rateDecimals) {
            assert(quote.abs() == base.abs());
        } else if (er.rate < er.rateDecimals) {
            assert(quote.abs() < base.abs());
        } else if (er.rate > er.rateDecimals) {
            assert(quote.abs() > base.abs());
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
        assertRateDirection(result, balance, er);

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