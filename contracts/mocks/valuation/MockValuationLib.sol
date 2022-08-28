// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../internal/valuation/ExchangeRate.sol";
import "../../internal/markets/AssetRate.sol";
import "../../internal/valuation/AssetHandler.sol";
import "../../internal/portfolio/PortfolioHandler.sol";
import "../../internal/AccountContextHandler.sol";
import "../../internal/nToken/nTokenHandler.sol";
import "../../internal/nToken/nTokenSupply.sol";
import "../../internal/nToken/nTokenCalculations.sol";
import "../../internal/markets/Market.sol";
import "../../global/LibStorage.sol";

/**
 * Exposes manual getters and setters for all the valuation and liquidation mocks. These
 * are the relevant settings required for the valuation and liquidation flows:
 *  - Asset Rate
 *  - Exchange Rate
 *  - Cash Group
 *  - nToken Parameters, Supply and Value
 *  - Markets
 *
 * Per Account: Balances and Portfolio Type
 */
library MockValuationLib {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountContext;
    using Market for MarketParameters;
    using nTokenHandler for nTokenPortfolio;
    using CashGroup for CashGroupParameters;

    function setAssetRateMapping(uint256 id, AssetRateStorage calldata rs) external {
        mapping(uint256 => AssetRateStorage) storage assetStore = LibStorage.getAssetRateStorage();
        assetStore[id] = rs;
    }

    function setETHRateMapping(uint256 id, ETHRateStorage calldata rs) external {
        mapping(uint256 => ETHRateStorage) storage ethStore = LibStorage.getExchangeRateStorage();
        ethStore[id] = rs;
    }

    function setCashGroup(uint256 id, CashGroupSettings calldata cg) external {
        CashGroup.setCashGroupStorage(id, cg);
    }

    function setNTokenValue(
        uint16 currencyId,
        address nTokenAddress,
        uint96 totalSupply,
        int88 cashBalance,
        uint8 pvHaircutPercentage,
        uint8 liquidationHaircutPercentage,
        uint256 lastInitializedTime
    ) public {
        nTokenHandler.setNTokenAddress(currencyId, nTokenAddress);
        nTokenHandler.setNTokenCollateralParameters(
            nTokenAddress,
            0,
            pvHaircutPercentage,
            0,
            0,
            liquidationHaircutPercentage
        );
        nTokenHandler.setArrayLengthAndInitializedTime(nTokenAddress, 0, lastInitializedTime);
        nTokenSupply.changeNTokenSupply(nTokenAddress, totalSupply, block.timestamp);
        BalanceHandler.setBalanceStorageForNToken(nTokenAddress, currencyId, cashBalance);
    }

    function setMarketStorage(
        uint256 currencyId,
        uint256 settlementDate,
        MarketParameters memory market
    ) public {
        market.setMarketStorageForInitialize(currencyId, settlementDate);
    }

    function setBalance(
        address account,
        uint256 currencyId,
        int256 cashBalance,
        int256 nTokenBalance
    ) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        if (cashBalance < 0)
            accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_CASH_DEBT;
        accountContext.setActiveCurrency(currencyId, true, Constants.ACTIVE_IN_BALANCES);
        accountContext.setAccountContext(account);

        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage
            .getBalanceStorage();
        BalanceStorage storage balanceStorage = store[account][currencyId];

        balanceStorage.nTokenBalance = uint80(nTokenBalance);
        balanceStorage.cashBalance = int88(cashBalance);
    }

    function setPortfolioState(address account, PortfolioState memory state) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.storeAssetsAndUpdateContext(account, state, true);
        accountContext.setAccountContext(account);
    }

    function setPortfolio(address account, PortfolioAsset[] memory assets) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory portfolioState = PortfolioHandler.buildPortfolioState(
            account,
            accountContext.assetArrayLength,
            0
        );
        portfolioState.addMultipleAssets(assets);
        accountContext.storeAssetsAndUpdateContext(account, portfolioState, false);
        accountContext.setAccountContext(account);
    }

    function enableBitmapForAccount(
        address account,
        uint16 currencyId,
        uint256 blockTime
    ) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.bitmapCurrencyId = currencyId;
        accountContext.nextSettleTime = uint40(DateTime.getTimeUTC0(blockTime));
        accountContext.setAccountContext(account);
    }

    function setifCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity,
        int256 notional
    ) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        int256 finalNotional = BitmapAssetsHandler.addifCashAsset(
            account,
            currencyId,
            maturity,
            accountContext.nextSettleTime,
            notional
        );
        if (finalNotional < 0)
            accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_ASSET_DEBT;

        accountContext.setAccountContext(account);
    }

    // View Methods Start Here
    function convertToUnderlying(uint256 currencyId, int256 balance) public view returns (int256) {
        AssetRateParameters memory assetRate = AssetRate.buildAssetRateView(currencyId);
        return AssetRate.convertToUnderlying(assetRate, balance);
    }

    function convertFromUnderlying(uint256 currencyId, int256 balance)
        public
        view
        returns (int256)
    {
        AssetRateParameters memory assetRate = AssetRate.buildAssetRateView(currencyId);
        return AssetRate.convertFromUnderlying(assetRate, balance);
    }

    function convertToETH(uint256 currencyId, int256 balance) public view returns (int256) {
        ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
        return ExchangeRate.convertToETH(ethRate, balance);
    }

    function convertETHTo(uint256 currencyId, int256 balance) public view returns (int256) {
        ETHRate memory ethRate = ExchangeRate.buildExchangeRate(currencyId);
        return ExchangeRate.convertETHTo(ethRate, balance);
    }

    function getAccount(address account)
        external
        view
        returns (
            AccountContext memory accountContext,
            AccountBalance[] memory accountBalances,
            PortfolioAsset[] memory portfolio
        )
    {
        accountContext = AccountContextHandler.getAccountContext(account);
        accountBalances = new AccountBalance[](10);

        uint256 i = 0;
        if (accountContext.isBitmapEnabled()) {
            AccountBalance memory b = accountBalances[0];
            b.currencyId = accountContext.bitmapCurrencyId;
            (
                b.cashBalance,
                b.nTokenBalance,
                b.lastClaimTime,
                b.accountIncentiveDebt
            ) = BalanceHandler.getBalanceStorage(account, accountContext.bitmapCurrencyId);
            i += 1;
        }

        bytes18 currencies = accountContext.activeCurrencies;
        while (currencies != 0) {
            AccountBalance memory b = accountBalances[i];
            b.currencyId = uint16(bytes2(currencies) & Constants.UNMASK_FLAGS);
            if (b.currencyId == 0) break;

            (
                b.cashBalance,
                b.nTokenBalance,
                b.lastClaimTime,
                b.accountIncentiveDebt
            ) = BalanceHandler.getBalanceStorage(account, b.currencyId);
            i += 1;
            currencies = currencies << 16;
        }

        if (accountContext.isBitmapEnabled()) {
            portfolio = BitmapAssetsHandler.getifCashArray(
                account,
                accountContext.bitmapCurrencyId,
                accountContext.nextSettleTime
            );
        } else {
            portfolio = PortfolioHandler.getSortedPortfolio(
                account,
                accountContext.assetArrayLength
            );
        }
    }

    function getNTokenPV(uint16 currencyId) external view returns (int256) {
        nTokenPortfolio memory nToken;
        nToken.loadNTokenPortfolioView(currencyId);
        return nTokenCalculations.getNTokenAssetPV(nToken, block.timestamp);
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
}

contract MockValuationBase {
    function setAssetRateMapping(uint256 id, AssetRateStorage calldata rs) external {
        MockValuationLib.setAssetRateMapping(id, rs);
    }

    function setETHRateMapping(uint256 id, ETHRateStorage calldata rs) external {
        MockValuationLib.setETHRateMapping(id, rs);
    }

    function setCashGroup(uint256 id, CashGroupSettings calldata cg) external {
        MockValuationLib.setCashGroup(id, cg);
    }

    function setNTokenValue(
        uint16 currencyId,
        address nTokenAddress,
        uint96 totalSupply,
        int88 cashBalance,
        uint8 pvHaircutPercentage,
        uint8 liquidationHaircutPercentage,
        uint256 lastInitializedTime
    ) public {
        MockValuationLib.setNTokenValue(
            currencyId,
            nTokenAddress,
            totalSupply,
            cashBalance,
            pvHaircutPercentage,
            liquidationHaircutPercentage,
            lastInitializedTime
        );
    }

    function setMarketStorage(
        uint256 currencyId,
        uint256 settlementDate,
        MarketParameters memory market
    ) public {
        MockValuationLib.setMarketStorage(currencyId, settlementDate, market);
    }

    function setBalance(
        address account,
        uint256 currencyId,
        int256 cashBalance,
        int256 nTokenBalance
    ) external {
        MockValuationLib.setBalance(account, currencyId, cashBalance, nTokenBalance);
    }

    function setPortfolioState(address account, PortfolioState memory state) external {
        MockValuationLib.setPortfolioState(account, state);
    }

    function setPortfolio(address account, PortfolioAsset[] memory assets) external {
        MockValuationLib.setPortfolio(account, assets);
    }

    function enableBitmapForAccount(
        address account,
        uint16 currencyId,
        uint256 blockTime
    ) external {
        MockValuationLib.enableBitmapForAccount(account, currencyId, blockTime);
    }

    function setifCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity,
        int256 notional
    ) external {
        MockValuationLib.setifCashAsset(account, currencyId, maturity, notional);
    }

    // View Methods Start Here
    // function convertToUnderlying(uint256 currencyId, int256 balance) public view returns (int256) {
    //     return MockValuationLib.convertToUnderlying(currencyId, balance);
    // }

    // function convertFromUnderlying(uint256 currencyId, int256 balance) public view returns (int256) {
    //     return MockValuationLib.convertFromUnderlying(currencyId, balance);
    // }

    // function convertToETH(uint256 currencyId, int256 balance) public view returns (int256) {
    //     return MockValuationLib.convertToETH(currencyId, balance);
    // }

    // function convertFromETH(uint256 currencyId, int256 balance) public view returns (int256) {
    //     return MockValuationLib.convertETHTo(currencyId, balance);
    // }

    // function getNTokenPV(uint16 currencyId) external view returns (int256) {
    //     return MockValuationLib.getNTokenPV(currencyId);
    // }

    function getAccount(address account)
        external
        view
        returns (
            AccountContext memory accountContext,
            AccountBalance[] memory accountBalances,
            PortfolioAsset[] memory portfolio
        )
    {
        return MockValuationLib.getAccount(account);
    }

    function getActiveMarkets(uint16 currencyId) external view returns (MarketParameters[] memory) {
        return MockValuationLib.getActiveMarkets(currencyId);
    }

    function getRiskAdjustedPresentfCashValue(PortfolioAsset memory asset, uint256 blockTime)
        external
        view
        returns (int256)
    {
        return MockValuationLib.getRiskAdjustedPresentfCashValue(asset, blockTime);
    }

    function getAccountContext(address account) external view returns (AccountContext memory) {
        return AccountContextHandler.getAccountContext(account);
    }

    function getLiquidityTokenHaircuts(uint16 currencyId) external view returns (uint8[] memory) {
        return MockValuationLib.getLiquidityTokenHaircuts(currencyId);
    }

    function calculateOracleRate(
        uint16 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) external view returns (uint256) {
        return MockValuationLib.calculateOracleRate(currencyId, maturity, blockTime);
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

    function getPresentfCashValue(
        int256 notional,
        uint256 maturity,
        uint256 blockTime,
        uint256 oracleRate
    ) external pure returns (int256) {
        return MockValuationLib.getPresentfCashValue(notional, maturity, blockTime, oracleRate);
    }

}
