// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/CashGroup.sol";
import "../storage/StorageLayoutV1.sol";

contract MockCashGroup is StorageLayoutV1 {
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;

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
        cashGroupMapping[id] = cg;
    }

    function setMarketState(MarketParameters memory ms) external {
        ms.setMarketStorage();
    }

    function getMarketState(
        uint id,
        uint maturity,
        uint blockTime,
        uint timeWindow
    ) external view returns (MarketParameters memory) {
        MarketParameters memory market;
        market.loadMarket(id, maturity, blockTime, true, timeWindow);
        return market;
    }

    function getTradedMarket(uint index) public pure returns (uint) {
        return CashGroup.getTradedMarket(index);
    }

    function isValidMaturity(
       CashGroupParameters memory cashGroup,
       uint maturity,
       uint blockTime
    ) public pure returns (bool) {
        bool isValid = cashGroup.isValidMaturity(maturity, blockTime);
        if (maturity < blockTime) assert(!isValid);

        return isValid;
    }

    function isValidIdiosyncraticMaturity(
       CashGroupParameters memory cashGroup,
       uint maturity,
       uint blockTime
    ) public pure returns (bool) {
        bool isValid = cashGroup.isValidIdiosyncraticMaturity(maturity, blockTime);

        return isValid;
    }

    function getBitNumFromMaturity(
        uint blockTime,
        uint maturity
    ) public pure returns (uint, bool) {
        (uint bitNum, bool isValid) = CashGroup.getBitNumFromMaturity(blockTime, maturity);
        assert(bitNum <= 256);
        if (isValid) assert(bitNum > 0);

        return (bitNum, isValid);
    }

    function getMaturityFromBitNum(
        uint blockTime,
        uint bitNum
    ) public pure returns (uint) {
        uint maturity = CashGroup.getMaturityFromBitNum(blockTime, bitNum);
        assert(maturity > blockTime);

        return maturity;
    }

    function getRateScalar(
        CashGroupParameters memory cashGroup,
        uint timeToMaturity
    ) public pure returns (int) {
        int rateScalar = cashGroup.getRateScalar(timeToMaturity);

        return rateScalar;
    }

    function getLiquidityFee(
        CashGroupParameters memory cashGroup,
        uint timeToMaturity
    ) public pure returns (uint) {
        uint fee = cashGroup.getLiquidityFee(timeToMaturity);

        return fee;
    }

    function getLiquidityHaircut(
        CashGroupParameters memory cashGroup,
        uint timeToMaturity
    ) public pure returns (uint) {
        return cashGroup.getLiquidityHaircut(timeToMaturity);
    }

    function getfCashHaircut(
        CashGroupParameters memory cashGroup
    ) public pure returns (uint) {
        return cashGroup.getfCashHaircut();
    }

    function getDebtBuffer(
        CashGroupParameters memory cashGroup
    ) public pure returns (uint) {
        return cashGroup.getDebtBuffer();
    }

    function getRateOracleTimeWindow(
        CashGroupParameters memory cashGroup
    ) public pure returns (uint) {
        return cashGroup.getRateOracleTimeWindow();
    }

    function getMarketIndex(
        CashGroupParameters memory cashGroup,
        uint maturity,
        uint blockTime
    ) public pure returns (uint, bool) {
        return cashGroup.getMarketIndex(maturity, blockTime);
    }

    function getMarket(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint marketIndex,
        uint blockTime,
        bool needsLiquidity
    ) public view returns (MarketParameters memory) {
        MarketParameters memory market = cashGroup.getMarket(markets, marketIndex, blockTime, needsLiquidity);

        // Ensure that the market cache gets updated via the memory reference
        assert(markets[marketIndex - 1].totalfCash == market.totalfCash);
        assert(markets[marketIndex - 1].totalCurrentCash == market.totalCurrentCash);
        assert(markets[marketIndex - 1].totalLiquidity == market.totalLiquidity);
        assert(markets[marketIndex - 1].lastImpliedRate == market.lastImpliedRate);
        assert(markets[marketIndex - 1].oracleRate == market.oracleRate);
        assert(markets[marketIndex - 1].previousTradeTime == market.previousTradeTime);

        return market;
    }

    function interpolateOracleRate(
        uint shortMaturity,
        uint longMaturity,
        uint shortRate,
        uint longRate,
        uint assetMaturity
    ) public pure returns (uint) {
        uint rate = CashGroup.interpolateOracleRate(
            shortMaturity,
            longMaturity,
            shortRate,
            longRate,
            assetMaturity
        );

        if (shortRate == longRate) {
            assert(rate == shortRate);
        } else if (shortRate < longRate) {
            assert(shortRate < rate && rate < longRate);
        } else {
            assert(shortRate > rate && rate > longRate);
        }

        return rate;
    }

    function getOracleRate(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint assetMaturity,
        uint blockTime
    ) public view returns (uint) {
        return cashGroup.getOracleRate(markets, assetMaturity, blockTime);
    }

    function buildCashGroup(
        uint currencyId
    ) public view returns (
        CashGroupParameters memory,
        MarketParameters[] memory
    ) {
        return CashGroup.buildCashGroup(currencyId);
    }

}