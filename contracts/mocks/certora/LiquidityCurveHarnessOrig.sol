// SPDX-License-Identifier: GPL-3.0-only
 pragma solidity >0.7.0;
 pragma experimental ABIEncoderV2;

 import "../../internal/markets/CashGroup.sol";
 import "../../internal/markets/Market.sol";

 contract LiquidityCurveHarnessOrig {
     using CashGroup for CashGroupParameters;
     using Market for MarketParameters;

     uint256 private constant MARKET_INDEX = 1;
     uint256 private constant CURRENCY_ID = 1;
     uint256 public constant MATURITY = 86400 * 360 * 30;

     function getRateScalar(uint256 timeToMaturity) external view returns (int256) {
         CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(CURRENCY_ID);
         return cashGroup.getRateScalar(MARKET_INDEX, timeToMaturity);
     }

     function _loadMarket() internal view returns (MarketParameters memory) {
         CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(CURRENCY_ID);
         MarketParameters memory market;
         market.loadMarket(
             CURRENCY_ID,
             MATURITY,
             block.timestamp,
             true,
             cashGroup.getRateOracleTimeWindow()
         );

         return market;
     }

     function getStoredOracleRate() external view returns (uint256) {
         uint256 settlementDate = DateTime.getReferenceTime(block.timestamp) + Constants.QUARTER;
         bytes32 slot = Market.getSlot(CURRENCY_ID, settlementDate, MATURITY);
         bytes32 data;

         assembly {
             data := sload(slot)
         }

         uint256 oracleRate = uint256(uint32(uint256(data >> 192)));

         return oracleRate;
     }

     function getLastImpliedRate() external view returns (uint256) {
         return _loadMarket().lastImpliedRate;
     }

     function getPreviousTradeTime() external view returns (uint256) {
         return _loadMarket().previousTradeTime;
     }

     function getMarketOracleRate() external view returns (uint256) {
         return _loadMarket().oracleRate;
     }

     function getMarketfCash() external view returns (uint256) {
         MarketParameters memory market = _loadMarket();
         require(market.totalfCash >= 0);
         return uint256(market.totalfCash);
     }

     function getMarketAssetCash() external view returns (uint256) {
         MarketParameters memory market = _loadMarket();
         require(market.totalAssetCash >= 0);
         return uint256(market.totalfCash);
     }

     function getMarketLiquidity() external view returns (uint256) {
         MarketParameters memory market = _loadMarket();
         require(market.totalLiquidity >= 0);
         return uint256(market.totalLiquidity);
     }

     function executeTrade(uint256 timeToMaturity, int256 fCashToAccount)
         external
         returns (int256, int256)
     {
         CashGroupParameters memory cashGroup = CashGroup.buildCashGroupStateful(CURRENCY_ID);
         MarketParameters memory market = _loadMarket();
         (int256 netAssetCash, int256 netAssetCashToReserve) =
             market.calculateTrade(cashGroup, fCashToAccount, timeToMaturity, MARKET_INDEX);
         market.setMarketStorage();
         return (netAssetCash, netAssetCashToReserve);
     }

     function addLiquidity(int256 assetCash) external {
         MarketParameters memory market = _loadMarket();
         market.addLiquidity(assetCash);
         market.setMarketStorage();
     }

     function removeLiquidity(int256 tokensToRemove) external {
         MarketParameters memory market = _loadMarket();
         market.removeLiquidity(tokensToRemove);
         market.setMarketStorage();
     }
 }