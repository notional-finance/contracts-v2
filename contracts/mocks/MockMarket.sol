// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/Market.sol";
import "../storage/StorageLayoutV1.sol";

contract MockMarket is StorageLayoutV1 {
    using Market for MarketParameters;

    function getUint64(uint value) public pure returns (int128) {
        return ABDKMath64x64.fromUInt(value);
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
       MarketParameters calldata marketState,
       CashGroupParameters calldata cashGroup,
       int fCashAmount,
       uint timeToMaturity
   ) external view returns (MarketParameters memory, int) {
        int assetCash = marketState.calculateTrade(
           cashGroup,
           fCashAmount,
           timeToMaturity
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
        return Market.buildMarket(
            currencyId,
            maturity,
            blockTime,
            needsLiquidity,
            rateOracleTimeWindow
        );
    }

}