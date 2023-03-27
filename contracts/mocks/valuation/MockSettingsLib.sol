// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../global/Types.sol";
import "../../internal/AccountContextHandler.sol";
import "../../internal/portfolio/PortfolioHandler.sol";
import "../../internal/markets/Market.sol";
import "../../internal/nToken/nTokenHandler.sol";
import "../../internal/balances/TokenHandler.sol";
import "../../internal/balances/BalanceHandler.sol";
import "../../internal/portfolio/BitmapAssetsHandler.sol";

contract MockSettingsLib {
    using PortfolioHandler for PortfolioState;
    using Market for MarketParameters;
    using AccountContextHandler for AccountContext;
    using PrimeRateLib for PrimeRate;
    using nTokenHandler for nTokenPortfolio;

    /// @notice Emits when the totalPrimeDebt changes due to borrowing
    event PrimeDebtChanged(
        uint16 indexed currencyId,
        uint256 totalPrimeSupply,
        uint256 totalPrimeDebt
    );

    /// @notice Emits when the totalPrimeSupply changes due to token deposits or withdraws
    event PrimeSupplyChanged(
        uint16 indexed currencyId,
        uint256 totalPrimeSupply,
        uint256 lastTotalUnderlyingValue
    );

    /// @notice Emitted when a settlement rate is set
    event SetPrimeSettlementRate(
        uint256 indexed currencyId,
        uint256 indexed maturity,
        int256 supplyFactor,
        int256 debtFactor
    );

    event Transfer(address indexed from, address indexed to, uint256 value);

    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 value
    );

    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] values
    );

    function convertToUnderlying(
        PrimeRate memory pr,
        int256 primeCashBalance
    ) external pure returns (int256) {
        return pr.convertToUnderlying(primeCashBalance);
    }

    function convertFromUnderlying(
        PrimeRate memory pr,
        int256 underlyingBalance
    ) external pure returns (int256) {
        return pr.convertFromUnderlying(underlyingBalance);
    }

    function convertFromStorage(
        PrimeRate memory pr,
        int256 storedBalance
    ) external pure returns (int256) {
        return pr.convertFromStorage(storedBalance);
    }

    function getPrimeFactors(uint16 currencyId) external view returns (PrimeCashFactors memory) {
        return PrimeCashExchangeRate.getPrimeCashFactors(currencyId);
    }
    
    function buildPrimeRateView(
        uint16 currencyId,
        uint256 blockTime
    ) external view returns (PrimeRate memory, PrimeCashFactors memory) {
        return PrimeCashExchangeRate.getPrimeCashRateView(currencyId, blockTime);
    }

    function buildPrimeRateStateful(
        uint16 currencyId
    ) external returns (PrimeRate memory) {
        return PrimeRateLib.buildPrimeRateStateful(currencyId);
    }

    function initPrimeCashCurve(
        uint16 currencyId,
        uint88 totalPrimeSupply,
        uint88 totalPrimeDebt,
        InterestRateCurveSettings calldata debtCurve,
        IPrimeCashHoldingsOracle oracle,
        bool allowDebt
    ) external {
        PrimeCashExchangeRate.initTokenBalanceStorage(currencyId, oracle);

        PrimeCashExchangeRate.initPrimeCashCurve(
            currencyId, totalPrimeSupply, debtCurve, oracle, allowDebt, 12
        );

        PrimeCashExchangeRate.setProxyAddress({
            currencyId: currencyId, proxy: address(this), isCashProxy: true
        });

        if (allowDebt) {
            PrimeCashExchangeRate.setProxyAddress({
                currencyId: currencyId, proxy: address(this), isCashProxy: false
            });

            PrimeCashExchangeRate.updateTotalPrimeDebt(
                address(0), currencyId, totalPrimeDebt, totalPrimeDebt
            );
        }
        
    } 

    function updateTotalPrimeDebt(
        uint16 currencyId,
        int256 netPrimeDebtChange,
        int256 netPrimeSupplyChange
    ) external {
        PrimeRateLib.buildPrimeRateStateful(currencyId);
        PrimeCashExchangeRate.updateTotalPrimeDebt(address(0), currencyId, netPrimeDebtChange, netPrimeSupplyChange);
    }

    function setBalance(
        address account,
        uint16 currencyId,
        int256 cashBalance,
        int256 nTokenBalance
    ) external {
        PrimeRate memory pr = PrimeRateLib.buildPrimeRateStateful(currencyId);
        AccountContext memory ctx = AccountContextHandler.getAccountContext(account);
        BalanceHandler._setBalanceStorage(account, currencyId, cashBalance, nTokenBalance, 0, 0, pr);
        ctx.setActiveCurrency(currencyId, true, Constants.ACTIVE_IN_BALANCES);
        if (cashBalance < 0) {
            ctx.hasDebt = ctx.hasDebt | Constants.HAS_CASH_DEBT;
        }
        AccountContextHandler.setAccountContext(ctx, account);
    }

    function getRawBalance(
        address account,
        uint16 currencyId
    ) external view returns (BalanceStorage memory) {
        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage.getBalanceStorage();
        BalanceStorage storage balanceStorage = store[account][currencyId];
        return balanceStorage;
    }

    function getBalance(
        address account,
        uint16 currencyId,
        uint256 blockTime
    ) external view returns (
        int256 cashBalance,
        int256 nTokenBalance,
        uint256 lastClaimTime,
        uint256 accountIncentiveDebt
    ) {
        return BalanceHandler.getBalanceStorageView(account, currencyId, blockTime);
    }

    // get / set account context
    function getAccountContext(address account) external view returns (AccountContext memory) {
        return AccountContextHandler.getAccountContext(account);
    }

    function setAccountContext(address account, AccountContext memory a) external {
        a.setAccountContext(account);
    }

    // get / set portfolio
    function buildPortfolioState(address account) external view returns (PortfolioState memory) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        return PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);
    }

    function addAsset(
        PortfolioState memory portfolioState,
        uint16 currencyId,
        uint256 maturity,
        uint256 assetType,
        int256 notional
    ) public pure returns (PortfolioState memory) {
        portfolioState.addAsset(currencyId, maturity, assetType, notional);

        return portfolioState;
    }

    function setPortfolio(address account, PortfolioState memory state) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.storeAssetsAndUpdateContext(account, state);
        accountContext.setAccountContext(account);
    }

    function getPortfolio(address account) external view returns (PortfolioAsset[] memory) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        return PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength);
    }

    // get / set ifCash
    function getBitmapAssets(address account) external view returns (PortfolioAsset[] memory) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        return BitmapAssetsHandler.getifCashArray(
            account,
            accountContext.bitmapCurrencyId,
            accountContext.nextSettleTime
        );
    }

    function setBitmapAssets(address account, PortfolioAsset[] memory a) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        BitmapAssetsHandler.addMultipleifCashAssets(account, accountContext, a);
        accountContext.setAccountContext(account);
    }

    // get / set markets
    function setMarket(
        uint256 currencyId,
        uint256 settlementDate,
        MarketParameters memory market
    ) external {
        market.setMarketStorageForInitialize(currencyId, settlementDate);
    }

    function getMarket(
        uint256 currencyId,
        uint256 maturity,
        uint256 settlementDate
    ) external view returns (MarketParameters memory s) {
        Market.loadSettlementMarket(s, currencyId, maturity, settlementDate);
    }

    // get / set cash groups
    function setCashGroup(uint256 id, CashGroupSettings calldata cg) external {
        CashGroup.setCashGroupStorage(id, cg);
    }

    // get / set interest rate curve
    function setInterestRateParameters(uint16 currencyId, uint256 marketIndex, InterestRateCurveSettings calldata settings) external {
        InterestRateCurve.setNextInterestRateParameters(currencyId, marketIndex, settings);
        InterestRateCurve.setActiveInterestRateParameters(currencyId);
    }

    function getInterestRate(
        uint16 currencyId,
        uint8 marketIndex,
        MarketParameters memory market
    ) external view returns (uint256) {
        InterestRateParameters memory irParams = InterestRateCurve.getActiveInterestRateParameters(
            currencyId, marketIndex
        );

        return InterestRateCurve.getInterestRate(
            irParams,
            InterestRateCurve.getfCashUtilization(0, market.totalfCash, market.totalPrimeCash / 50)
        );
    }
    
    // get / set nToken
    function setNToken(
        uint16 currencyId,
        address tokenAddress,
        PortfolioAsset[] memory liquidityTokens,
        PortfolioAsset[] memory fCash,
        uint96 totalSupply,
        int256 cashBalance,
        uint256 lastInitializedTime,
        uint8 pvHaircutPercentage,
        uint8 liquidationHaircutPercentage
    ) external {
        if (nTokenHandler.nTokenAddress(currencyId) == address(0)) {
            nTokenHandler.setNTokenAddress(currencyId, tokenAddress);
        }

        // Total Supply
        nTokenSupply.changeNTokenSupply(tokenAddress, totalSupply, block.timestamp);

        // Cash Balance
        BalanceHandler.setBalanceStorageForNToken(tokenAddress, currencyId, cashBalance);

        // Liquidity Tokens
        PortfolioState memory p = PortfolioHandler.buildPortfolioState(tokenAddress, 0, 0);
        p.newAssets = liquidityTokens;
        p.storeAssets(tokenAddress);
        nTokenHandler.setArrayLengthAndInitializedTime(
            tokenAddress,
            uint8(liquidityTokens.length),
            lastInitializedTime
        );

        // fCash
        for (uint i = 0; i < fCash.length; i++) {
            BitmapAssetsHandler.addifCashAsset(
                tokenAddress,
                fCash[i].currencyId,
                fCash[i].maturity,
                lastInitializedTime,
                fCash[i].notional
            );
        }

        nTokenHandler.setNTokenCollateralParameters(
            tokenAddress,
            0,
            pvHaircutPercentage,
            0,
            0,
            liquidationHaircutPercentage
        );
    }

    function setETHRate(uint256 id, ETHRateStorage calldata rs) external {
        mapping(uint256 => ETHRateStorage) storage ethStore = LibStorage.getExchangeRateStorage();
        ethStore[id] = rs;
    }

    function getTotalfCashDebtOutstanding(uint16 currencyId, uint256 maturity) external view returns (int256) {
        return PrimeCashExchangeRate.getTotalfCashDebtOutstanding(currencyId, maturity);
    }

    function setTotalfCashDebtOutstanding(uint16 currencyId, uint256 maturity, int256 totalDebt) external {
        mapping(uint256 => mapping(uint256 => TotalfCashDebtStorage)) storage store = LibStorage.getTotalfCashDebtOutstanding();
        store[currencyId][maturity].totalfCashDebt = uint80(uint256(-totalDebt));
    }

    function getNTokenAddress(uint16 currencyId) external view returns (address) {
        return nTokenHandler.nTokenAddress(currencyId);
    }

    function getETHRate(uint256 id) external view returns (ETHRateStorage memory) {
        mapping(uint256 => ETHRateStorage) storage ethStore = LibStorage.getExchangeRateStorage();
        return ethStore[id];
    }

    function getToken(uint16 currencyId) external view returns (Token memory) {
        return TokenHandler.getUnderlyingToken(currencyId);
    }

    function setMaxUnderlyingSupply(uint16 currencyId, uint256 maxUnderlying) external {
        PrimeCashExchangeRate.setMaxUnderlyingSupply(currencyId, maxUnderlying);
    }

    function getPrimeInterestRates(
        uint16 currencyId
    ) external view returns (
        uint256 annualDebtRatePreFee,
        uint256 annualDebtRatePostFee,
        uint256 annualSupplyRate
    ) {
        PrimeCashFactors memory p = PrimeCashExchangeRate.getPrimeCashFactors(currencyId);
        return PrimeCashExchangeRate.getPrimeInterestRates(currencyId, p);
    }

    function buildPrimeSettlementRateStateful(uint16 currencyId, uint256 maturity) external {
        PrimeRateLib.buildPrimeRateSettlementStateful(currencyId, maturity, block.timestamp);
    }

    function getStoredTokenBalances(address[] calldata tokens) external view returns (uint256[] memory balances) {
        mapping(address => uint256) storage store = LibStorage.getStoredTokenBalances();
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = store[tokens[i]];
        }
    }

    function setStoredTokenBalance(address token, uint256 balance) external {
        mapping(address => uint256) storage store = LibStorage.getStoredTokenBalances();
        store[token] = balance;
    }

}