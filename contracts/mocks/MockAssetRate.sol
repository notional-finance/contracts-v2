// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;
pragma abicoder v2;

import "../internal/markets/AssetRate.sol";
import "../global/StorageLayoutV1.sol";

contract MockAssetRate is StorageLayoutV1 {
    event SetSettlementRate(uint256 indexed currencyId, uint256 indexed maturity, uint128 rate);

    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;

    function setAssetRateMapping(uint256 id, AssetRateStorage calldata rs) external {
        mapping(uint256 => AssetRateStorage) storage assetStore = LibStorage.getAssetRateStorage();
        assetStore[id] = rs;
    }

    function assertBalanceSign(int256 balance, int256 result) private pure {
        if (balance == 0) assert(result == 0);
        else if (balance < 0) assert(result < 0);
        else if (balance > 0) assert(result > 0);
    }

    function convertToUnderlying(AssetRateParameters memory er, IA balance)
        external
        pure
        returns (int256)
    {
        require(er.rate > 0);
        int256 result = IU.unwrap(er.convertToUnderlying(balance));
        assertBalanceSign(IA.unwrap(balance), result);

        return result;
    }

    function convertFromUnderlying(AssetRateParameters memory er, IU balance)
        external
        pure
        returns (int256)
    {
        require(er.rate > 0);
        int256 result = IA.unwrap(er.convertFromUnderlying(balance));
        assertBalanceSign(IU.unwrap(balance), result);

        return result;
    }

    function buildAssetRate(uint256 currencyId) external returns (AssetRateParameters memory) {
        AssetRateParameters memory assetRateStateful = AssetRate.buildAssetRateStateful(currencyId);
        AssetRateParameters memory assetRateView = AssetRate.buildAssetRateView(currencyId);

        assert(assetRateStateful.rate == assetRateView.rate);
        assert(assetRateStateful.underlyingDecimals == assetRateView.underlyingDecimals);
        assert(assetRateStateful.rateOracle == assetRateView.rateOracle);

        return assetRateStateful;
    }

    function buildAssetRateStateful(uint256 currencyId)
        external
        returns (AssetRateParameters memory)
    {
        return AssetRate.buildAssetRateStateful(currencyId);
    }

    function buildSettlementRate(
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) external returns (AssetRateParameters memory) {
        AssetRateParameters memory initialViewRate =
            AssetRate.buildSettlementRateView(currencyId, maturity);

        AssetRateParameters memory statefulRate =
            AssetRate.buildSettlementRateStateful(currencyId, maturity, blockTime);

        assert(initialViewRate.rate == statefulRate.rate);
        assert(initialViewRate.underlyingDecimals == statefulRate.underlyingDecimals);

        return statefulRate;
    }
}
