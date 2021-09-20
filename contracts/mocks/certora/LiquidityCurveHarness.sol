// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/markets/CashGroup.sol";
import "../../internal/markets/Market.sol";

// import "../../math/ABDKMath64x64.sol";

contract LiquidityCurveHarness {
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;

    CashGroupParameters symbolicCashGroup;
    MarketParameters symbolicMarket;

    uint256 private constant MARKET_INDEX = 1;
    uint16 private constant CURRENCY_ID = 1;
    uint256 public constant MATURITY = 86400 * 360 * 30;

    function getRateScalar(uint256 timeToMaturity) external view returns (int256) {
        // CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(CURRENCY_ID);
        return symbolicCashGroup.getRateScalar(MARKET_INDEX, timeToMaturity);
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

    function getRateOracleTimeWindow() external view returns (uint256) {
        // CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(CURRENCY_ID);
        return symbolicCashGroup.getRateOracleTimeWindow();
    }

    function getStoredOracleRate() external view returns (uint256) {
        uint256 settlementDate = DateTime.getReferenceTime(block.timestamp) + Constants.QUARTER;
        // bytes32 slot = Market.getSlot(CURRENCY_ID, settlementDate, MATURITY);
        // bytes32 data;

        // assembly {
        //     data := sload(slot)
        // }

        // uint256 oracleRate = uint256(uint32(uint256(data >> 192)));

        return 0;
    }

    function getLastImpliedRate() external view returns (uint256) {
        // return _loadMarket().lastImpliedRate;
        return symbolicMarket.lastImpliedRate;
    }

    function getPreviousTradeTime() external view returns (uint256) {
        // return _loadMarket().previousTradeTime;
        return symbolicMarket.previousTradeTime;
    }

    function getMarketOracleRate() external view returns (uint256) {
        // return _loadMarket().oracleRate;
        return symbolicMarket.oracleRate;
    }

    function getMarketfCash() external view returns (int256) {
        // return _loadMarket().totalfCash;
        return symbolicMarket.totalfCash;
    }

    function getMarketAssetCash() external view returns (int256) {
        // return _loadMarket().totalAssetCash;
        return symbolicMarket.totalAssetCash;
    }

    function getMarketLiquidity() external view returns (int256) {
        // return _loadMarket().totalLiquidity;
        return symbolicMarket.totalLiquidity;
    }

    function executeTrade(uint256 timeToMaturity, int256 fCashToAccount)
        external
        returns (int256, int256)
    {
        CashGroupParameters memory cashGroup = symbolicCashGroup; //CashGroup.buildCashGroupStateful(CURRENCY_ID);
        MarketParameters memory market = symbolicMarket; //_loadMarket();
        (int256 netAssetCash, int256 netAssetCashToReserve) = market.calculateTrade(
            cashGroup,
            fCashToAccount,
            timeToMaturity,
            MARKET_INDEX
        );
        symbolicMarket = market;
        symbolicCashGroup = cashGroup;
        return (netAssetCash, netAssetCashToReserve);
    }

    function addLiquidity(int256 assetCash) external returns (int256, int256) {
        MarketParameters memory market = symbolicMarket; //_loadMarket();
        int256 marketfCashBefore = market.totalfCash;
        (int256 liquidityTokens, int256 fCashToAccount) = market.addLiquidity(assetCash);
        symbolicMarket = market;

        // Check the assertion in here because the prover does not handle negative integers
        assert((market.totalfCash + fCashToAccount) == marketfCashBefore);

        return (liquidityTokens, fCashToAccount);
    }

    function removeLiquidity(int256 tokensToRemove) external returns (int256, int256) {
        MarketParameters memory market = symbolicMarket; //_loadMarket();
        (int256 assetCash, int256 fCash) = market.removeLiquidity(tokensToRemove);
        symbolicMarket = market;
        return (assetCash, fCash);
    }

    function getRateAnchor(
        int256 totalfCash,
        uint256 lastImpliedRate,
        int256 totalCashUnderlying,
        uint256 timeToMaturity
    ) external view returns (int256) {
        int256 rateScalar = this.getRateScalar(timeToMaturity);
        (int256 rateAnchor, bool success) = Market._getRateAnchor(
            totalfCash,
            lastImpliedRate,
            totalCashUnderlying,
            rateScalar,
            timeToMaturity
        );
        require(success);
        return rateAnchor;
    }

    function getImpliedRate(
        int256 totalfCash,
        int256 totalCashUnderlying,
        int256 rateAnchor,
        uint256 timeToMaturity
    ) external view returns (uint256) {
        int256 rateScalar = this.getRateScalar(timeToMaturity);

        return
            Market.getImpliedRate(
                totalfCash,
                totalCashUnderlying,
                rateScalar,
                rateAnchor,
                timeToMaturity
            );
    }

    function getExchangeRate(
        int256 totalfCash,
        int256 totalCashUnderlying,
        int256 rateScalar,
        int256 rateAnchor,
        int256 fCashToAccount
    ) external view returns (int256) {
        (int256 exchangeRate, bool success) = Market._getExchangeRate(
            totalfCash,
            totalCashUnderlying,
            rateScalar,
            rateAnchor,
            fCashToAccount
        );
        require(success);

        return exchangeRate;
    }

    ///////////////////////////////
    //  general purpose functions
    ///////////////////////////////

    function a_minus_b(int256 a, int256 b) public returns (int256) {
        return a - b;
    }

    function isEqual(int256 a, int256 b) public returns (bool) {
        return a == b;
    }
}
