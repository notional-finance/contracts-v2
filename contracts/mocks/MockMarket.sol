// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/AssetRate.sol";
import "../common/Market.sol";
import "../storage/StorageLayoutV1.sol";

contract MockMarket is StorageLayoutV1 {
    using Market for MarketParameters;
    using AssetRate for AssetRateParameters;

    function getUint64(uint value) public pure returns (int128) {
        return ABDKMath64x64.fromUInt(value);
    }

    function setAssetRateMapping(
        uint id,
        AssetRateStorage calldata rs
    ) external {
        assetToUnderlyingRateMapping[id] = rs;
    }

    function setCashGroup(
        uint id,
        CashGroupParameterStorage calldata cg
    ) external {
        CashGroup.setCashGroupStorage(id, cg);
    }

    function buildCashGroupView(
        uint currencyId
    ) public view returns (
        CashGroupParameters memory,
        MarketParameters[] memory
    ) {
        return CashGroup.buildCashGroupView(currencyId);
    }

    function getExchangeRate(
        int totalfCash,
        int totalCashUnderlying,
        int rateScalar,
        int rateAnchor,
        int fCashAmount
    ) external pure returns (int, bool) {
        return Market.getExchangeRate(
            totalfCash,
            totalCashUnderlying,
            rateScalar,
            rateAnchor,
            fCashAmount
        );
    }

    function logProportion(int proportion) external pure returns (int, bool) {
        return Market.logProportion(proportion);
    }

    function getImpliedRate(
        int totalfCash,
        int totalCashUnderlying,
        int rateScalar,
        int rateAnchor,
        uint timeToMaturity
    ) external pure returns (uint, bool) {
        return Market.getImpliedRate(
            totalfCash,
            totalCashUnderlying,
            rateScalar,
            rateAnchor,
            timeToMaturity
        );
    }

    function getRateAnchor(
        int totalfCash,
        uint lastImpliedRate,
        int totalCashUnderlying,
        int rateScalar,
        uint timeToMaturity
    ) external pure returns (int, bool) {
        return Market.getRateAnchor(
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
       int fCashAmount,
       uint timeToMaturity,
       uint marketIndex
   ) external view returns (MarketParameters memory, int) {
        int assetCash = marketState.calculateTrade(
           cashGroup,
           fCashAmount,
           timeToMaturity,
           marketIndex
        );

        return (marketState, assetCash);
   }

   function setMarketStorage(MarketParameters memory market) public {
       market.setMarketStorage();
   }

   function buildMarket(
        uint currencyId,
        uint maturity,
        uint blockTime,
        bool needsLiquidity,
        uint rateOracleTimeWindow
    ) public view returns (MarketParameters memory) {
        MarketParameters memory market;
        market.loadMarket(currencyId, maturity, blockTime, needsLiquidity, rateOracleTimeWindow);
        return market;
    }

}