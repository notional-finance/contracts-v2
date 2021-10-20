// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;
pragma abicoder v2;

import "../internal/valuation/AssetHandler.sol";
import "../internal/markets/Market.sol";
import "../global/StorageLayoutV1.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract MockAssetHandler is StorageLayoutV1 {
    using UserDefinedType for IA;
    using UserDefinedType for IU;
    using SafeInt256 for int256;
    using AssetHandler for PortfolioAsset;
    using Market for MarketParameters;

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

    function setMarketStorage(
        uint256 currencyId,
        uint256 settlementDate,
        MarketParameters memory market
    ) public {
        market.setMarketStorageForInitialize(currencyId, settlementDate);
    }

    function getMarketStorage(
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) public view returns (MarketParameters memory) {
        MarketParameters memory market;
        Market.loadMarket(market, currencyId, maturity, blockTime, true, 1);

        return market;
    }

    function getSettlementDate(PortfolioAsset memory asset) public pure returns (uint256) {
        return asset.getSettlementDate();
    }

    function getPresentValue(
        IU notional,
        uint256 maturity,
        uint256 blockTime,
        IR oracleRate
    ) public pure returns (IU) {
        IU pv = AssetHandler.getPresentfCashValue(notional, maturity, blockTime, oracleRate);
        if (notional.isPosNotZero()) assert(pv.isPosNotZero());
        if (notional.isNegNotZero()) assert(pv.isNegNotZero());

        assert(pv.abs().lte(notional.abs()));
        return pv;
    }

    function getRiskAdjustedPresentValue(
        CashGroupParameters memory cashGroup,
        IU notional,
        uint256 maturity,
        uint256 blockTime,
        IR oracleRate
    ) public pure returns (IU) {
        IU riskPv =
            AssetHandler.getRiskAdjustedPresentfCashValue(
                cashGroup,
                notional,
                maturity,
                blockTime,
                oracleRate
            );
        IU pv = getPresentValue(notional, maturity, blockTime, oracleRate);

        assert(riskPv.lte(pv));
        assert(riskPv.abs().lte(notional.abs()));
        return riskPv;
    }

    function getCashClaims(
        PortfolioAsset memory liquidityToken,
        MarketParameters memory marketState
    ) public pure returns (IA, IU) {
        (IA cash, IU fCash) = liquidityToken.getCashClaims(marketState);
        assert(cash.isPosNotZero());
        assert(fCash.isPosNotZero());
        assert(cash.lte(marketState.totalAssetCash));
        assert(fCash.lte(marketState.totalfCash));

        return (cash, fCash);
    }

    function getHaircutCashClaims(
        PortfolioAsset memory liquidityToken,
        MarketParameters memory marketState,
        CashGroupParameters memory cashGroup
    ) public pure returns (IA, IU) {
        (IA haircutCash, IU haircutfCash) =
            liquidityToken.getHaircutCashClaims(marketState, cashGroup);
        (IA cash, IU fCash) = liquidityToken.getCashClaims(marketState);

        assert(haircutCash.lt(cash));
        assert(haircutfCash.lt(fCash));

        return (haircutCash, haircutfCash);
    }

    function getLiquidityTokenValueRiskAdjusted(
        uint256 index,
        CashGroupParameters memory cashGroup,
        PortfolioAsset[] memory assets,
        uint256 blockTime
    )
        public
        view
        returns (
            IA,
            IU,
            PortfolioAsset[] memory
        )
    {
        MarketParameters memory market;
        (IA assetValue, IU pv) =
            AssetHandler.getLiquidityTokenValue(index, cashGroup, market, assets, blockTime, true);

        return (assetValue, pv, assets);
    }

    function getLiquidityTokenValue(
        uint256 index,
        CashGroupParameters memory cashGroup,
        PortfolioAsset[] memory assets,
        uint256 blockTime
    )
        public
        view
        returns (
            IA,
            IU,
            PortfolioAsset[] memory
        )
    {
        MarketParameters memory market;
        (IA assetValue, IU pv) =
            AssetHandler.getLiquidityTokenValue(index, cashGroup, market, assets, blockTime, false);

        return (assetValue, pv, assets);
    }

    function getNetCashGroupValue(
        PortfolioAsset[] memory assets,
        CashGroupParameters memory cashGroup,
        uint256 blockTime,
        uint256 portfolioIndex
    ) public view returns (IA, uint256) {
        MarketParameters memory market;
        return
            AssetHandler.getNetCashGroupValue(assets, cashGroup, market, blockTime, portfolioIndex);
    }
}
