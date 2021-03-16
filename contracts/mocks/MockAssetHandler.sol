// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/AssetHandler.sol";
import "../common/Market.sol";
import "../storage/StorageLayoutV1.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";

contract MockAssetHandler is StorageLayoutV1 {
    using SafeInt256 for int256;
    using AssetHandler for PortfolioAsset;
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

    function setMarketStorage(
        uint currencyId,
        uint settlementDate,
        MarketParameters memory market
    ) public {
        market.storageSlot = Market.getSlot(currencyId, settlementDate, market.maturity);
        // ensure that state gets set
        market.storageState = 0xFF;
        market.setMarketStorage();
   }

    function getMarketStorage(
        uint currencyId,
        uint settlementDate,
        uint maturity,
        uint blockTime
    ) public view returns (MarketParameters memory) {
        MarketParameters memory market;
        Market.loadMarket(market, currencyId, maturity, blockTime, true, 1);

        return market;
    }

    function getSettlementDate(
        PortfolioAsset memory asset
    ) public pure returns (uint) {
        return asset.getSettlementDate();
    }

    function getPresentValue(
        int notional,
        uint maturity,
        uint blockTime,
        uint oracleRate
    ) public pure returns (int) {
        int pv = AssetHandler.getPresentValue(notional, maturity, blockTime, oracleRate);
        if (notional > 0) assert(pv > 0);
        if (notional < 0) assert(pv < 0);

        assert(pv.abs() < notional.abs());
        return pv;
    }

    function getRiskAdjustedPresentValue(
        CashGroupParameters memory cashGroup,
        int notional,
        uint maturity,
        uint blockTime,
        uint oracleRate
    ) public pure returns (int) {
        int riskPv = AssetHandler.getRiskAdjustedPresentValue(cashGroup, notional, maturity, blockTime, oracleRate);
        int pv = getPresentValue(notional, maturity, blockTime, oracleRate);

        assert(riskPv <= pv);
        assert(riskPv.abs() <= notional.abs());
        return riskPv;
    }

    function getCashClaims(
        PortfolioAsset memory liquidityToken,
        MarketParameters memory marketState
    ) public pure returns (int, int) {
        (int cash, int fCash) = liquidityToken.getCashClaims(marketState);
        assert(cash > 0);
        assert(fCash > 0);
        assert(cash <= marketState.totalCurrentCash);
        assert(fCash <= marketState.totalfCash);

        return (cash, fCash);
    }

    function getHaircutCashClaims(
        PortfolioAsset memory liquidityToken,
        MarketParameters memory marketState,
        CashGroupParameters memory cashGroup
    ) public pure returns (int, int) {
        (int haircutCash, int haircutfCash) = liquidityToken.getHaircutCashClaims(
            marketState, cashGroup
        );
        (int cash, int fCash) = liquidityToken.getCashClaims(marketState);

        assert(haircutCash < cash);
        assert(haircutfCash < fCash);

        return (haircutCash, haircutfCash);
    }

    function getLiquidityTokenValueRiskAdjusted(
        PortfolioAsset memory liquidityToken,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        PortfolioAsset[] memory fCashAssets,
        uint blockTime
    ) public view returns (int, int, PortfolioAsset[] memory) {
        (int assetValue, int pv) = liquidityToken.getLiquidityTokenValue(
            cashGroup,
            markets,
            fCashAssets,
            blockTime,
            true
        );

        return (assetValue, pv, fCashAssets);
    }

    function getLiquidityTokenValue(
        PortfolioAsset memory liquidityToken,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        PortfolioAsset[] memory fCashAssets,
        uint blockTime
    ) public view returns (int, int, PortfolioAsset[] memory) {
        (int assetValue, int pv) = liquidityToken.getLiquidityTokenValue(
            cashGroup,
            markets,
            fCashAssets,
            blockTime,
            false
        );

        return (assetValue, pv, fCashAssets);
    }

    function getRiskAdjustedPortfolioValue(
        PortfolioAsset[] memory assets,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory markets,
        uint blockTime
    ) public view returns(int[] memory) {
        int[] memory assetValue = AssetHandler.getPortfolioValue(
            assets,
            cashGroups,
            markets,
            blockTime,
            // Set risk adjusted to true
            true
        );

        return assetValue;
    }

    function getPortfolioValue(
        PortfolioAsset[] memory assets,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory markets,
        uint blockTime
    ) public view returns(int[] memory) {
        int[] memory assetValue = AssetHandler.getPortfolioValue(
            assets,
            cashGroups,
            markets,
            blockTime,
            // Set risk adjusted to true
            false
        );

        return assetValue;
    }
}