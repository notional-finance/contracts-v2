// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../global/Types.sol";
import "../internal/markets/CashGroup.sol";
import "../global/StorageLayoutV1.sol";
import "./valuation/AbstractSettingsRouter.sol";

contract MockCashGroup is AbstractSettingsRouter {
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;

    constructor(address settingsLib) AbstractSettingsRouter(settingsLib) { }

    function setCashGroup(uint256 id, CashGroupSettings calldata cg) external {
        CashGroup.setCashGroupStorage(id, cg);
    }

    function setMarketState(
        uint256 currencyId,
        uint256 settlementDate,
        MarketParameters memory market
    ) external {
        market.setMarketStorageForInitialize(currencyId, settlementDate);
    }

    function getMarketState(
        uint256 id,
        uint256 maturity,
        uint256 blockTime,
        uint256 timeWindow
    ) external view returns (MarketParameters memory) {
        MarketParameters memory market;
        market.loadMarket(id, maturity, blockTime, true, timeWindow);
        return market;
    }

    function getTradedMarket(uint256 index) public pure returns (uint256) {
        return DateTime.getTradedMarket(index);
    }

    function isValidMarketMaturity(
        uint256 maxMarketIndex,
        uint256 maturity,
        uint256 blockTime
    ) public pure returns (bool) {
        bool isValid = DateTime.isValidMarketMaturity(maxMarketIndex, maturity, blockTime);
        if (maturity < blockTime) assert(!isValid);

        return isValid;
    }

    function isValidMaturity(
        uint256 maxMarketIndex,
        uint256 maturity,
        uint256 blockTime
    ) public pure returns (bool) {
        bool isValid = DateTime.isValidMaturity(maxMarketIndex, maturity, blockTime);

        return isValid;
    }

    function getBitNumFromMaturity(uint256 blockTime, uint256 maturity)
        public
        pure
        returns (uint256, bool)
    {
        (uint256 bitNum, bool isValid) = DateTime.getBitNumFromMaturity(blockTime, maturity);
        assert(bitNum <= 256);
        if (isValid) assert(bitNum > 0);

        return (bitNum, isValid);
    }

    function getMaturityFromBitNum(uint256 blockTime, uint256 bitNum)
        public
        pure
        returns (uint256)
    {
        uint256 maturity = DateTime.getMaturityFromBitNum(blockTime, bitNum);
        assert(maturity > blockTime);

        return maturity;
    }

    function getReserveFeeShare(CashGroupParameters memory cashGroup) public pure returns (int256) {
        return cashGroup.getReserveFeeShare();
    }

    function getfCashHaircut(CashGroupParameters memory cashGroup) public pure returns (uint256) {
        return cashGroup.getfCashHaircut();
    }

    function getDebtBuffer(CashGroupParameters memory cashGroup) public pure returns (uint256) {
        return cashGroup.getDebtBuffer();
    }

    function getRateOracleTimeWindow(CashGroupParameters memory cashGroup)
        public
        pure
        returns (uint256)
    {
        return cashGroup.getRateOracleTimeWindow();
    }

    function getMaxDiscountFactor(CashGroupParameters memory cashGroup)
        public
        pure
        returns (int256)
    {
        return cashGroup.getMaxDiscountFactor();
    }

    function getMinOracleRate(CashGroupParameters memory cashGroup, uint256 marketIndex)
        public
        pure
        returns (uint256)
    {
        return cashGroup.getMinOracleRate(marketIndex);
    }

    function getMaxOracleRate(CashGroupParameters memory cashGroup, uint256 marketIndex)
        public
        pure
        returns (uint256)
    {
        return cashGroup.getMaxOracleRate(marketIndex);
    }

    function getLiquidationfCashHaircut(CashGroupParameters memory cashGroup)
        public
        pure
        returns (uint256)
    {
        return cashGroup.getLiquidationfCashHaircut();
    }

    function getLiquidationDebtBuffer(CashGroupParameters memory cashGroup)
        public
        pure
        returns (uint256)
    {
        return cashGroup.getLiquidationDebtBuffer();
    }

    function getMarketIndex(
        uint256 maxMarketIndex,
        uint256 maturity,
        uint256 blockTime
    ) public pure returns (uint256, bool) {
        return DateTime.getMarketIndex(maxMarketIndex, maturity, blockTime);
    }

    function loadMarket(
        CashGroupParameters memory cashGroup,
        uint256 marketIndex,
        bool needsLiquidity,
        uint256 blockTime
    ) public view returns (MarketParameters memory market) {
        cashGroup.loadMarket(market, marketIndex, needsLiquidity, blockTime);
    }

    function interpolateOracleRate(
        uint256 shortMaturity,
        uint256 longMaturity,
        uint256 shortRate,
        uint256 longRate,
        uint256 assetMaturity
    ) public pure returns (uint256) {
        uint256 rate =
            CashGroup.interpolateOracleRate(
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

    function calculateOracleRate(
        CashGroupParameters memory cashGroup,
        uint256 assetMaturity,
        uint256 blockTime
    ) public view returns (uint256) {
        return cashGroup.calculateOracleRate(assetMaturity, blockTime);
    }

    function buildCashGroupView(uint16 currencyId)
        public
        view
        returns (CashGroupParameters memory)
    {
        return CashGroup.buildCashGroupView(currencyId);
    }

    function buildCashGroupStateful(uint16 currencyId)
        public
        returns (CashGroupParameters memory)
    {
        return CashGroup.buildCashGroupStateful(currencyId);
    }

    function deserializeCashGroupStorage(uint16 currencyId)
        public
        view
        returns (CashGroupSettings memory)
    {
        return CashGroup.deserializeCashGroupStorage(currencyId);
    }
}
