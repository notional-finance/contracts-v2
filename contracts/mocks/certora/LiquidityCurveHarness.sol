// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/markets/CashGroup.sol";
import "../../internal/markets/Market.sol";
// import "../../math/ABDKMath64x64.sol";

contract LiquidityCurveHarness {
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;

    // using Market for mapping(uint256=>mapping(uint256=>mapping(uint256 => MarketParameters)));

    // mapping(uint256=>mapping(uint256=>mapping(uint256 => MarketParameters))) public symbolicMarkets;

    CashGroupParameters symbolicCashGroupStorage;

    MarketParameters symbolicMarket;

    uint256 private constant MARKET_INDEX = 1;
    uint256 private constant CURRENCY_ID = 1;
    uint256 public constant MATURITY = 86400 * 360 * 30;

   function getRateScalar(uint256 timeToMaturity) external returns (int256) {
        // CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(CURRENCY_ID);
        // CashGroupParameters memory cashGroup = symbolicCashGroup; //CashGroup.buildCashGroupView(CURRENCY_ID);
        // return symbolicCashGroup.getRateScalar(MARKET_INDEX, timeToMaturity);
        symbolicCashGroupStorage._buildCashGroupView(CURRENCY_ID);
        return symbolicCashGroupStorage.getRateScalarStorage(MARKET_INDEX, timeToMaturity);
    }

    function _loadMarket() internal returns(uint256 settlementDate) { // CERTORA: now returning the settlementDate // returns (MarketParameters memory) {
         symbolicCashGroupStorage._buildCashGroupView(CURRENCY_ID);
        // CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(CURRENCY_ID);
        // MarketParameters memory market;
        settlementDate = symbolicMarket.loadMarket(
            CURRENCY_ID,
            MATURITY,
            block.timestamp,
            true,
            symbolicCashGroupStorage.getRateOracleTimeWindowStorage()
        );
       // return market;
    }

    function getRateOracleTimeWindow() external returns (uint256) {
        symbolicCashGroupStorage._buildCashGroupView(CURRENCY_ID);
        // CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(CURRENCY_ID);
        // CashGroupParameters memory cashGroup = symbolicCashGroup;
        // return cashGroup.getRateOracleTimeWindow();
        // return symbolicCashGroup.getRateOracleTimeWindow();
        return symbolicCashGroupStorage.getRateOracleTimeWindowStorage();
    }

    function getStoredOracleRate() external view returns (uint256) {
        uint256 settlementDate = DateTime.getReferenceTime(block.timestamp) + Constants.QUARTER;
        bytes32 marketSlot = Market.getMarketSlot(CURRENCY_ID, settlementDate, MATURITY);
        return Market.oracleRateStorage(marketSlot);
        
        // Instead we could write:
        // return symbolicMarkets[CURRENCY_ID][settlementDate][MATURITY].oracleRateStorage;


        // bytes32 slot = Market.getSlot(CURRENCY_ID, settlementDate, MATURITY);
        // bytes32 data;

        // assembly {
        //     data := sload(slot)
        // }

        // uint256 oracleRate = uint256(uint32(uint256(data >> 192)));

        // return oracleRate;
    }

    function getLastImpliedRate() external returns (uint256) {
        // uint256 settlementDate = _loadMarket();
         _loadMarket();
        // return symbolicMarkets[CURRENCY_ID][settlementDate][MATURITY].lastImpliedRate;
        // return _loadMarket().lastImpliedRate;
        return symbolicMarket.lastImpliedRate;
    }

    function getPreviousTradeTime() external returns (uint256) {
        // uint256 settlementDate = _loadMarket();
         _loadMarket();
        // return symbolicMarkets[CURRENCY_ID][settlementDate][MATURITY].previousTradeTime;
        return symbolicMarket.previousTradeTime;
    }

    function getMarketOracleRate() external returns (uint256) {
        // uint256 settlementDate = _loadMarket();
         _loadMarket();
        // return symbolicMarkets[CURRENCY_ID][settlementDate][MATURITY].oracleRate;
        // return _loadMarket().oracleRate;
        return symbolicMarket.oracleRate;
    }

    function getMarketfCash() external returns (int256) {
        // uint256 settlementDate = _loadMarket();
         _loadMarket();
        // return symbolicMarkets[CURRENCY_ID][settlementDate][MATURITY].totalfCash;
        // return _loadMarket().totalfCash;
        return symbolicMarket.totalfCash;
    }

    function getMarketAssetCash() external returns (int256) {
        // uint256 settlementDate = _loadMarket();
         _loadMarket();
        // return symbolicMarkets[CURRENCY_ID][settlementDate][MATURITY].totalAssetCash;
        // return _loadMarket().totalAssetCash;
        return symbolicMarket.totalAssetCash;
    }

    function getMarketLiquidity() external returns (int256) {
        // uint256 settlementDate = _loadMarket();
         _loadMarket();
        // return symbolicMarkets[CURRENCY_ID][settlementDate][MATURITY].totalLiquidity;
        // return _loadMarket().totalLiquidity;
        return symbolicMarket.totalLiquidity;
    }

    function executeTrade(uint256 timeToMaturity, int256 fCashToAccount)
        external
        returns (int256, int256)
    {
        // CashGroupParameters memory cashGroup = symbolicCashGroup; //CashGroup.buildCashGroupStateful(CURRENCY_ID);
        // CashGroupParameters memory cashGroup = CashGroup.buildCashGroupStateful(CURRENCY_ID);
        symbolicCashGroupStorage._buildCashGroupStateful(CURRENCY_ID);
        // MarketParameters memory market = symbolicMarket; //_loadMarket();
        //MarketParameters memory market = _loadMarket();
        //  uint256 settlementDate = _loadMarket();
         _loadMarket();
        //  MarketParameters storage market = symbolicMarkets[CURRENCY_ID][settlementDate][MATURITY];
        (int256 netAssetCash, int256 netAssetCashToReserve) =
            Market.calculateTrade(symbolicMarket, symbolicCashGroupStorage, fCashToAccount, timeToMaturity, MARKET_INDEX);
        // Market.setMarketStorage(market);
        symbolicMarket.setMarketStorage();
        // symbolicMarket = market;
        // symbolicCashGroup = cashGroup;
        return (netAssetCash, netAssetCashToReserve);
    }

    function addLiquidity(int256 assetCash) external returns (int256, int256) {
        // MarketParameters memory market = symbolicMarket; //_loadMarket();
        // MarketParameters memory market = _loadMarket();
        //  uint256 settlementDate = _loadMarket();
         _loadMarket();
        //  MarketParameters storage market = symbolicMarkets[CURRENCY_ID][settlementDate][MATURITY];
        // int256 marketfCashBefore = market.totalfCash;
        (int256 liquidityTokens, int256 fCashToAccount) = symbolicMarket.addLiquidity( assetCash);
        // Market.setMarketStorage(market);
        symbolicMarket.setMarketStorage();
        // symbolicMarket = market;

        return (liquidityTokens, fCashToAccount);
    }

    function removeLiquidity(int256 tokensToRemove) external returns (int256, int256) {
        // MarketParameters memory market = symbolicMarket; //_loadMarket();
        // MarketParameters memory market = _loadMarket();
        //  uint256 settlementDate = _loadMarket();
         _loadMarket();
        //  MarketParameters storage market = symbolicMarkets[CURRENCY_ID][settlementDate][MATURITY];
        (int256 assetCash, int256 fCash) = symbolicMarket.removeLiquidity(tokensToRemove);
        // Market.setMarketStorage(market);
        symbolicMarket.setMarketStorage();
        // symbolicMarket = market;
        return (assetCash, fCash);
    }

    ///////////////////////////////
    //  general purpose functions 
    ///////////////////////////////

    function a_minus_b(int256 a, int256 b) public returns (int256) {
        return a - b;
    }
    function a_plus_b(int256 a, int256 b) public returns (int256) {
        return a + b;
    }
    function isEqual(int256 a, int256 b) public returns (bool) {
        return a == b;
    }
}
