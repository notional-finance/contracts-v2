// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/AssetRate.sol";
import "../storage/StorageLayoutV1.sol";

contract MockAssetRate is StorageLayoutV1 {
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;

    function setAssetRateMapping(
        uint id,
        AssetRateStorage calldata rs
    ) external {
        assetToUnderlyingRateMapping[id] = rs;
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
        AssetRateParameters memory er
    ) private pure {
        require(er.rate > 0);
        require(baseDecimals > 0);
        require(quoteDecimals > 0);

        if (base == 0) return;

        int baseInQuoteDecimals = base.mul(quoteDecimals).div(baseDecimals).abs();
        int quoteAbs = quote.abs();
        if (er.rate == AssetRate.ASSET_RATE_DECIMALS) {
            assert(quoteAbs == baseInQuoteDecimals);
        } else if (er.rate < AssetRate.ASSET_RATE_DECIMALS) {
            assert(quoteAbs < baseInQuoteDecimals);
        } else if (er.rate > AssetRate.ASSET_RATE_DECIMALS) {
            assert(quoteAbs > baseInQuoteDecimals);
        }
    }

    function convertInternalToUnderlying(
        AssetRateParameters memory er,
        int balance
    ) external pure returns (int) {
        require(er.rate > 0);
        int result = er.convertInternalToUnderlying(balance);
        assertBalanceSign(balance, result);
        assertRateDirection(balance, result, Market.RATE_PRECISION, Market.RATE_PRECISION, er);

        return result;
    }

    function convertInternalFromUnderlying(
        AssetRateParameters memory er,
        int balance
    ) external pure returns (int) {
        require(er.rate > 0);
        int result = er.convertInternalFromUnderlying(balance);
        assertBalanceSign(balance, result);
        assertRateDirection(result, balance, Market.RATE_PRECISION, Market.RATE_PRECISION, er);

        return result;
    }

    function buildAssetRate(
        uint currencyId
    ) external view returns (AssetRateParameters memory) {
        return AssetRate.buildAssetRate(currencyId);
    }
}