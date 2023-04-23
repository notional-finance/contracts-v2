// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../internal/valuation/FreeCollateral.sol";
import "./MockValuationLib.sol";
import "./AbstractSettingsRouter.sol";

contract MockFreeCollateral is MockValuationLib, AbstractSettingsRouter {
    using SafeInt256 for int256;
    using AssetHandler for PortfolioAsset;
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountContext;
    using nTokenHandler for nTokenPortfolio;
    using Market for MarketParameters;
    using CashGroup for CashGroupParameters;

    event Liquidation(LiquidationFactors factors);
    event FreeCollateralResult(int256 fc, int256[] netLocal);
    event AccountContextUpdate(address indexed account);

    constructor(address settingsLib) AbstractSettingsRouter(settingsLib) { }

    function getNetCashGroupValue(
        PortfolioAsset[] memory assets,
        uint256 blockTime,
        uint256 portfolioIndex
    ) external view returns (int256, uint256) {
        uint16 currencyId = uint16(assets[portfolioIndex].currencyId);
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        return AssetHandler.getNetCashGroupValue(
            assets,
            cashGroup,
            blockTime,
            portfolioIndex
        );
    }

    function getFreeCollateralView(address account, uint256 blockTime)
        external
        view
        returns (int256, int256[] memory)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        return FreeCollateral.getFreeCollateralView(account, accountContext, blockTime);
    }

    function getFreeCollateralStateful(address account, uint256 blockTime)
        external
        returns (int256, bool)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        (int256 ethFC, bool updateContext) = FreeCollateral.getFreeCollateralStateful(account, accountContext, blockTime);
        if (updateContext) accountContext.setAccountContext(account);

        return (ethFC, updateContext);
    }

    function getLiquidationFactors(
        address account,
        uint256 localCurrencyId,
        uint256 collateralCurrencyId
    ) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        (LiquidationFactors memory factors, /* */) = FreeCollateral.getLiquidationFactors(
            account, accountContext, block.timestamp, localCurrencyId, collateralCurrencyId);
        emit Liquidation(factors);
    }

    function testFreeCollateral(address account)
        external
        returns (int256, int256[] memory)
    {
        // prettier-ignore
        AccountContext memory accountContextNew =
            AccountContextHandler.getAccountContext(account);
        // NOTE: buildPrimeRateStateful and buildCashGroup do not use the blockTime
        // parameter here
        (int256 ethDenominatedFC, bool updateContext) =
            FreeCollateral.getFreeCollateralStateful(account, accountContextNew, block.timestamp);

        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        // NOTE: buildPrimeRateView does use the blockTime parameter here
        (int256 fcView, int256[] memory netLocal) =
            FreeCollateral.getFreeCollateralView(account, accountContext, block.timestamp);

        if (updateContext) {
            accountContextNew.setAccountContext(account);
        }

        require(fcView == ethDenominatedFC);

        if (fcView < 0) {
            (LiquidationFactors memory factors, /* */) = FreeCollateral.getLiquidationFactors(
                account, accountContext, block.timestamp, 1, 0);
            emit Liquidation(factors);

            require(fcView == factors.netETHValue);
        }

        emit FreeCollateralResult(fcView, netLocal);
        return (fcView, netLocal);
    }

    function getSettlementDate(PortfolioAsset memory asset) public pure returns (uint256) {
        return AssetHandler.getSettlementDate(asset);
    }

    function getPresentValue(
        int256 notional,
        uint256 maturity,
        uint256 blockTime,
        uint256 oracleRate
    ) public pure returns (int256) {
        int256 pv = AssetHandler.getPresentfCashValue(notional, maturity, blockTime, oracleRate);
        if (notional > 0) assert(pv > 0);
        if (notional < 0) assert(pv < 0);

        assert(pv.abs() <= notional.abs());
        return pv;
    }

    function getRiskAdjustedPresentValue(
        uint16 currencyId,
        int256 notional,
        uint256 maturity,
        uint256 blockTime
    ) public view returns (int256 riskPv, int256 pv) {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        riskPv =
            AssetHandler.getRiskAdjustedPresentfCashValue(
                cashGroup,
                notional,
                maturity,
                blockTime
            );
        uint256 oracleRate = cashGroup.calculateOracleRate(maturity, blockTime);
        pv = getPresentValue(notional, maturity, blockTime, oracleRate);

        assert(riskPv <= pv);
        assert(riskPv.abs() <= notional.abs());
    }

    function getOracleRates(uint16 currencyId, uint256 maturity, uint256 blockTime, uint256 blockSupplyRate) public view returns (
        uint256 oracleRate,
        uint256 fCashOracleRate,
        uint256 debtOracleRate
    ) {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        cashGroup.primeRate.oracleSupplyRate = blockSupplyRate;
        oracleRate = cashGroup.calculateOracleRate(maturity, blockTime);
        fCashOracleRate = cashGroup.calculateRiskAdjustedfCashOracleRate(maturity, blockTime);
        debtOracleRate = cashGroup.calculateRiskAdjustedDebtOracleRate(maturity, blockTime);
    }

    function getCashClaims(
        PortfolioAsset memory liquidityToken,
        MarketParameters memory marketState
    ) public pure returns (int256, int256) {
        (int256 cash, int256 fCash) = liquidityToken.getCashClaims(marketState);
        assert(cash > 0);
        assert(fCash > 0);
        assert(cash <= marketState.totalPrimeCash);
        assert(fCash <= marketState.totalfCash);

        return (cash, fCash);
    }

    function getNToken(uint16 currencyId) external view returns (nTokenPortfolio memory) {
        nTokenPortfolio memory nToken;
        nToken.loadNTokenPortfolioView(currencyId);
        return nToken;
    }
}
