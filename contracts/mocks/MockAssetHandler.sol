// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/AssetHandler.sol";
import "../common/Market.sol";
import "../storage/StorageLayoutV1.sol";

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
        cashGroupMapping[id] = cg;
    }

    function setMarketState(MarketParameters memory ms) external {
        ms.setMarketStorage();
    }

    function getSettlementDate(
        PortfolioAsset memory asset
    ) public pure returns (uint) {
        return asset.getSettlementDate();
    }

    function getDiscountFactor(
        uint timeToMaturity,
        uint oracleRate
    ) public pure returns (int) {
        uint rate = SafeCast.toUint256(AssetHandler.getDiscountFactor(timeToMaturity, oracleRate));
        assert(rate >= oracleRate);

        return int(rate);
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
        CashGroupParameters memory cashGroup,
        uint blockTime
    ) public pure returns (int, int) {
        (int haircutCash, int haircutfCash) = liquidityToken.getHaircutCashClaims(
            marketState, cashGroup, blockTime
        );
        (int cash, int fCash) = liquidityToken.getCashClaims(marketState);

        assert(haircutCash < cash);
        assert(haircutfCash < fCash);

        return (haircutCash, haircutfCash);
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
            true
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
}