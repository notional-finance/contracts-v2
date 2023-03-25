// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../internal/valuation/ExchangeRate.sol";
import {PrimeRateLib} from "../../internal/pCash/PrimeRateLib.sol";
import {PrimeCashExchangeRate} from "../../internal/pCash/PrimeCashExchangeRate.sol";
import "../../internal/valuation/AssetHandler.sol";
import "../../internal/portfolio/PortfolioHandler.sol";
import "../../internal/AccountContextHandler.sol";
import "../../internal/nToken/nTokenHandler.sol";
import "../../internal/nToken/nTokenSupply.sol";
import "../../internal/nToken/nTokenCalculations.sol";
import "../../internal/markets/Market.sol";
import "../../global/LibStorage.sol";
import "../../global/Types.sol";

contract MockValuationLib {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountContext;
    using Market for MarketParameters;
    using nTokenHandler for nTokenPortfolio;
    using CashGroup for CashGroupParameters;

    function getNTokenPV(uint16 currencyId, uint256 blockTime) external view returns (int256) {
        nTokenPortfolio memory nToken;
        nToken.loadNTokenPortfolioView(currencyId);
        return nTokenCalculations.getNTokenPrimePV(nToken, blockTime);
    }

    function getActiveMarkets(uint16 currencyId) external view returns (MarketParameters[] memory) {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        MarketParameters[] memory markets = new MarketParameters[](cashGroup.maxMarketIndex);

        for (uint256 i = 0; i < cashGroup.maxMarketIndex; i++) {
            cashGroup.loadMarket(markets[i], i + 1, true, block.timestamp);
        }

        return markets;
    }

    function getRiskAdjustedPresentfCashValue(PortfolioAsset memory asset, uint256 blockTime)
        external
        view
        returns (int256)
    {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(
            uint16(asset.currencyId)
        );

        return
            AssetHandler.getRiskAdjustedPresentfCashValue(
                cashGroup,
                asset.notional,
                asset.maturity,
                blockTime,
                cashGroup.calculateOracleRate(asset.maturity, blockTime)
            );
    }

    function getPresentfCashValue(
        int256 notional,
        uint256 maturity,
        uint256 blockTime,
        uint256 oracleRate
    ) external pure returns (int256) {
        return
            AssetHandler.getPresentfCashValue(
                notional,
                maturity,
                blockTime,
                oracleRate
            );
    }

    function calculateOracleRate(
        uint16 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) external view returns (uint256) {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        return cashGroup.calculateOracleRate(maturity, blockTime);
    }

    function getLiquidityTokenHaircuts(uint16 currencyId) external view returns (uint8[] memory) {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        uint8[] memory haircuts = new uint8[](cashGroup.maxMarketIndex);

        for (uint256 i; i < haircuts.length; i++) {
            haircuts[i] = cashGroup.getLiquidityHaircut(i + 2);
        }

        return haircuts;
    }

    function getBitNumFromMaturity(uint256 blockTime, uint256 maturity)
        external
        pure
        returns (uint256, bool)
    {
        return DateTime.getBitNumFromMaturity(blockTime, maturity);
    }

    function getMaturityFromBitNum(uint256 blockTime, uint256 bitNum)
        external
        pure
        returns (uint256)
    {
        return DateTime.getMaturityFromBitNum(blockTime, bitNum);
    }

    function buildCashGroupView(uint16 currencyId)
        external
        view
        returns (CashGroupParameters memory)
    {
        return CashGroup.buildCashGroupView(currencyId);
    }

    function getCashGroup(uint16 currencyId)
        external
        view
        returns (CashGroupSettings memory)
    {
        return CashGroup.deserializeCashGroupStorage(currencyId);
    }

    function getETHRate(uint256 id) external view returns (ETHRateStorage memory) {
        mapping(uint256 => ETHRateStorage) storage ethStore = LibStorage.getExchangeRateStorage();
        return ethStore[id];
    }


}
