// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;
pragma abicoder v2;

import "../internal/markets/CashGroup.sol";
import "../internal/markets/AssetRate.sol";
import "../internal/markets/Market.sol";
import "../global/StorageLayoutV1.sol";

contract MockMarket is StorageLayoutV1 {
    using UserDefinedType for LT;
    using UserDefinedType for IA;
    using UserDefinedType for IU;
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;
    using AssetRate for AssetRateParameters;
    using SafeInt256 for int256;

    function getUint64(uint256 value) public pure returns (int128) {
        return ABDKMath64x64.fromUInt(value);
    }

    function setAssetRateMapping(uint256 id, AssetRateStorage calldata rs) external {
        mapping(uint256 => AssetRateStorage) storage assetStore = LibStorage.getAssetRateStorage();
        assetStore[id] = rs;
    }

    function setCashGroup(uint256 id, CashGroupSettings calldata cg) external {
        CashGroup.setCashGroupStorage(id, cg);
    }

    function buildCashGroupView(uint16 currencyId)
        public
        view
        returns (CashGroupParameters memory)
    {
        return CashGroup.buildCashGroupView(currencyId);
    }

    function getExchangeRate(
        IU totalfCash,
        IU totalCashUnderlying,
        int256 rateScalar,
        int256 rateAnchor,
        IU fCashAmount
    ) external pure returns (int256, bool) {
        return
            Market._getExchangeRate(
                totalfCash,
                totalCashUnderlying,
                rateScalar,
                rateAnchor,
                fCashAmount
            );
    }

    function logProportion(int256 proportion) external pure returns (int256, bool) {
        return Market._logProportion(proportion);
    }

    function getImpliedRate(
        IU totalfCash,
        IU totalCashUnderlying,
        int256 rateScalar,
        int256 rateAnchor,
        uint256 timeToMaturity
    ) external pure returns (uint256) {
        return
            Market.getImpliedRate(
                totalfCash,
                totalCashUnderlying,
                rateScalar,
                rateAnchor,
                timeToMaturity
            );
    }

    function getRateAnchor(
        IU totalfCash,
        uint256 lastImpliedRate,
        IU totalCashUnderlying,
        int256 rateScalar,
        uint256 timeToMaturity
    ) external pure returns (int256, bool) {
        return
            Market._getRateAnchor(
                totalfCash,
                lastImpliedRate,
                totalCashUnderlying,
                rateScalar,
                timeToMaturity
            );
    }

    function calculateTrade(
        MarketParameters memory marketState,
        CashGroupParameters memory cashGroup,
        IU fCashAmount,
        uint256 timeToMaturity,
        uint256 marketIndex
    )
        external
        view
        returns (
            MarketParameters memory,
            IA,
            IA
        )
    {
        (IA assetCash, IA fee) =
            marketState.calculateTrade(cashGroup, fCashAmount, timeToMaturity, marketIndex);

        return (marketState, assetCash, fee);
    }

    function addLiquidity(MarketParameters memory marketState, IA assetCash)
        public
        returns (
            MarketParameters memory,
            LT,
            IU
        )
    {
        (LT liquidityTokens, IU fCash) = marketState.addLiquidity(assetCash);
        assert(LT.unwrap(liquidityTokens) >= 0);
        assert(fCash.isNegOrZero());
        return (marketState, liquidityTokens, fCash);
    }

    function removeLiquidity(MarketParameters memory marketState, LT tokensToRemove)
        public
        returns (
            MarketParameters memory,
            IA,
            IU
        )
    {
        (IA assetCash, IU fCash) = marketState.removeLiquidity(tokensToRemove);

        assert(assetCash.isPosOrZero());
        assert(fCash.isPosOrZero());
        return (marketState, assetCash, fCash);
    }

    function setMarketStorage(
        uint256 currencyId,
        uint256 settlementDate,
        MarketParameters memory market
    ) public {
        market.setMarketStorageForInitialize(currencyId, settlementDate);
    }

    function getMarketStorageOracleRate(bytes32 slot) public view returns (uint256) {
        bytes32 data;

        assembly {
            data := sload(slot)
        }
        return uint256(uint32(uint256(data >> 192)));
    }

    function buildMarket(
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime,
        bool needsLiquidity,
        uint256 rateOracleTimeWindow
    ) public view returns (MarketParameters memory) {
        MarketParameters memory market;
        market.loadMarket(currencyId, maturity, blockTime, needsLiquidity, rateOracleTimeWindow);
        return market;
    }

    function getExchangeRateFactors(
        MarketParameters memory market,
        CashGroupParameters memory cashGroup,
        uint256 marketIndex,
        uint256 timeToMaturity
    ) external pure returns (int256, IU, int256) {
        return Market.getExchangeRateFactors(market, cashGroup, timeToMaturity, marketIndex);
    }

    function getfCashAmountGivenCashAmount(
        MarketParameters memory market,
        CashGroupParameters memory cashGroup,
        IU netCashToAccount,
        uint256 marketIndex,
        uint256 timeToMaturity,
        int256 maxfCashDelta
    ) external pure returns (IU) {
        (int256 rateScalar, IU totalCashUnderlying, int256 rateAnchor) =
            Market.getExchangeRateFactors(market, cashGroup, timeToMaturity, marketIndex);
        // Rate scalar can never be zero so this signifies a failure and we return zero
        if (rateScalar == 0) revert();
        int256 fee = Market.getExchangeRateFromImpliedRate(cashGroup.getTotalFee(), timeToMaturity);

        return
            Market.getfCashGivenCashAmount(
                market.totalfCash,
                netCashToAccount,
                totalCashUnderlying,
                rateScalar,
                rateAnchor,
                fee,
                maxfCashDelta
            );
    }
}
