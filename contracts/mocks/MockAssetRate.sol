// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/AssetRate.sol";
import "../storage/StorageLayoutV1.sol";

contract MockAssetRate is StorageLayoutV1 {
    event SetSettlementRate(uint currencyId, uint maturity, uint128 rate);

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

    function convertInternalToUnderlying(
        AssetRateParameters memory er,
        int balance
    ) external pure returns (int) {
        require(er.rate > 0);
        int result = er.convertInternalToUnderlying(balance);
        assertBalanceSign(balance, result);

        return result;
    }

    function convertInternalFromUnderlying(
        AssetRateParameters memory er,
        int balance
    ) external pure returns (int) {
        require(er.rate > 0);
        int result = er.convertInternalFromUnderlying(balance);
        assertBalanceSign(balance, result);

        return result;
    }

    function buildAssetRate(
        uint currencyId
    ) external view returns (AssetRateParameters memory) {
        return AssetRate.buildAssetRate(currencyId);
    }

    function buildSettlementRate(
        uint currencyId,
        uint maturity,
        uint blockTime
    ) external returns (AssetRateParameters memory) {
        (AssetRateParameters memory initialViewRate, /* */, /* */) = AssetRate.buildSettlementRateView(
            currencyId,
            maturity
        );

        AssetRateParameters memory statefulRate = AssetRate.buildSettlementRateStateful(
            currencyId,
            maturity,
            blockTime
        );

        assert (initialViewRate.rate == statefulRate.rate);
        assert (initialViewRate.underlyingDecimals == statefulRate.underlyingDecimals);

        return statefulRate;
    }
}