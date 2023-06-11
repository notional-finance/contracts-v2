// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    PrimeRate,
    ETHRate,
    Token,
    CashGroupParameters,
    MarketParameters,
    BalanceState,
    AccountContext,
    nTokenPortfolio,
    ETHRateStorage,
    AssetRateStorage,
    CashGroupSettings,
    InterestRateParameters,
    PrimeCashFactors,
    PortfolioAsset,
    AccountBalance,
    BalanceStorage,
    Deprecated_AssetRateParameters,
    RebalancingContextStorage,
    TotalfCashDebtStorage
} from "../global/Types.sol";
import {SafeUint256} from "../math/SafeUint256.sol";
import {SafeInt256} from "../math/SafeInt256.sol";
import {LibStorage} from "../global/LibStorage.sol";
import {StorageLayoutV2} from "../global/StorageLayoutV2.sol";
import {Deployments} from "../global/Deployments.sol";
import {Constants} from "../global/Constants.sol";

import {ExchangeRate} from "../internal/valuation/ExchangeRate.sol";
import {CashGroup} from "../internal/markets/CashGroup.sol";
import {Market} from "../internal/markets/Market.sol";
import {InterestRateCurve} from "../internal/markets/InterestRateCurve.sol";
import {DeprecatedAssetRate} from "../internal/markets/DeprecatedAssetRate.sol";
import {nTokenHandler} from "../internal/nToken/nTokenHandler.sol";
import {nTokenSupply} from "../internal/nToken/nTokenSupply.sol";
import {PrimeRateLib} from "../internal/pCash/PrimeRateLib.sol";
import {PrimeCashExchangeRate} from "../internal/pCash/PrimeCashExchangeRate.sol";
import {TokenHandler} from "../internal/balances/TokenHandler.sol";
import {BalanceHandler} from "../internal/balances/BalanceHandler.sol";
import {PortfolioHandler} from "../internal/portfolio/PortfolioHandler.sol";
import {BitmapAssetsHandler} from "../internal/portfolio/BitmapAssetsHandler.sol";
import {AccountContextHandler} from "../internal/AccountContextHandler.sol";
import {Emitter} from "../internal/Emitter.sol";

import {NotionalViews} from "../../interfaces/notional/NotionalViews.sol";
import {FreeCollateralExternal} from "./FreeCollateralExternal.sol";
import {MigrateIncentives} from "./MigrateIncentives.sol";

contract Views is StorageLayoutV2, NotionalViews {
    using CashGroup for CashGroupParameters;
    using TokenHandler for Token;
    using Market for MarketParameters;
    using PrimeRateLib for PrimeRate;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;
    using BalanceHandler for BalanceState;
    using nTokenHandler for nTokenPortfolio;
    using AccountContextHandler for AccountContext;

    function _checkValidCurrency(uint16 currencyId) internal view {
        require(0 < currencyId && currencyId <= maxCurrencyId, "Invalid currency id");
    }

    /** Governance Parameter Getters **/

    /// @notice Returns the current maximum currency id
    function getMaxCurrencyId() external view override returns (uint16) {
        return maxCurrencyId;
    }

    /// @notice Returns a currency id, a zero means that it is not listed.
    function getCurrencyId(address tokenAddress)
        external
        view
        override
        returns (uint16 currencyId)
    {
        currencyId = tokenAddressToCurrencyId[tokenAddress];
        require(currencyId != 0, "Token not listed");
    }

    /// @notice Returns the asset token and underlying token related to a given currency id. If underlying
    /// token is not set then will return the zero address
    function getCurrency(uint16 currencyId)
        external
        view
        override
        returns (Token memory assetToken, Token memory underlyingToken)
    {
        _checkValidCurrency(currencyId);
        assetToken = TokenHandler.getDeprecatedAssetToken(currencyId);
        underlyingToken = TokenHandler.getUnderlyingToken(currencyId);
    }

    /// @notice Returns the ETH and Asset rates for a currency as stored, useful for viewing how they are configured
    function getRateStorage(uint16 currencyId)
        external
        view
        override
        returns (ETHRateStorage memory ethRate, AssetRateStorage memory assetRate)
    {
        _checkValidCurrency(currencyId);
        mapping(uint256 => ETHRateStorage) storage ethStore = LibStorage.getExchangeRateStorage();
        mapping(uint256 => AssetRateStorage) storage assetStore = LibStorage.getAssetRateStorage_deprecated();
        ethRate = ethStore[currencyId];
        assetRate = assetStore[currencyId];
    }

    /// @notice Returns a currency and its corresponding asset rate and ETH exchange rates. Note that this does not recalculate
    /// cToken interest rates, it only retrieves the latest stored rate.
    function getCurrencyAndRates(uint16 currencyId)
        external
        view
        override
        returns (
            Token memory assetToken,
            Token memory underlyingToken,
            ETHRate memory ethRate,
            Deprecated_AssetRateParameters memory assetRate
        )
    {
        _checkValidCurrency(currencyId);
        assetToken = TokenHandler.getDeprecatedAssetToken(currencyId);
        underlyingToken = TokenHandler.getUnderlyingToken(currencyId);
        ethRate = ExchangeRate.buildExchangeRate(currencyId);
        assetRate = DeprecatedAssetRate.getAdaptedAssetRate(currencyId);
    }

    /// @notice Returns cash group settings for a currency
    function getCashGroup(uint16 currencyId)
        external
        view
        override
        returns (CashGroupSettings memory)
    {
        _checkValidCurrency(currencyId);
        return CashGroup.deserializeCashGroupStorage(currencyId);
    }

    /// @notice Returns the cash group along with the asset rate for convenience.
    function getCashGroupAndAssetRate(uint16 currencyId)
        external
        view
        override
        returns (CashGroupSettings memory cashGroup, Deprecated_AssetRateParameters memory assetRate)
    {
        _checkValidCurrency(currencyId);
        cashGroup = CashGroup.deserializeCashGroupStorage(currencyId);
        assetRate = DeprecatedAssetRate.getAdaptedAssetRate(currencyId);
    }

    /// @notice Returns market initialization parameters for a given currency
    function getInitializationParameters(uint16 currencyId)
        external view override returns (
            int256[] memory deprecated_annualizedAnchorRates,
            int256[] memory proportions
        ) {
        _checkValidCurrency(currencyId);
        uint256 maxMarketIndex = CashGroup.getMaxMarketIndex(currencyId);
        proportions = nTokenHandler.getInitializationParameters(
            currencyId,
            maxMarketIndex
        );
    }

    /// @notice Returns nToken deposit parameters for a given currency
    function getDepositParameters(uint16 currencyId)
        external
        view
        override
        returns (int256[] memory depositShares, int256[] memory leverageThresholds)
    {
        _checkValidCurrency(currencyId);
        uint256 maxMarketIndex = CashGroup.getMaxMarketIndex(currencyId);
        (depositShares, leverageThresholds) = nTokenHandler.getDepositParameters(
            currencyId,
            maxMarketIndex
        );
    }

    function getInterestRateCurve(uint16 currencyId) external view override returns (
        InterestRateParameters[] memory nextInterestRateCurve,
        InterestRateParameters[] memory activeInterestRateCurve
    ) {
        _checkValidCurrency(currencyId);
        uint256 maxMarketIndex = CashGroup.getMaxMarketIndex(currencyId);
        // If no markets are listed, just exit
        if (maxMarketIndex == 0) return (nextInterestRateCurve, activeInterestRateCurve);

        nextInterestRateCurve = new InterestRateParameters[](maxMarketIndex);
        activeInterestRateCurve = new InterestRateParameters[](maxMarketIndex);

        for (uint256 i = 1; i <= maxMarketIndex; i++) {
            nextInterestRateCurve[i - 1] = InterestRateCurve
                .getNextInterestRateParameters(currencyId, i);
            activeInterestRateCurve[i - 1] = InterestRateCurve
                .getActiveInterestRateParameters(currencyId, i);
        }
    }

    /// @notice Returns nToken address for a given currency
    function nTokenAddress(uint16 currencyId) external view override returns (address) {
        _checkValidCurrency(currencyId);
        address nToken = nTokenHandler.nTokenAddress(currencyId);
        require(nToken != address(0), "No nToken for currency");
        return nToken;
    }

    /// @notice Returns pCash address for a given currency
    function pCashAddress(uint16 currencyId) external view override returns (address) {
        _checkValidCurrency(currencyId);
        return PrimeCashExchangeRate.getCashProxyAddress(currencyId);
    }

    function pDebtAddress(uint16 currencyId) external view override returns (address) {
        _checkValidCurrency(currencyId);
        return PrimeCashExchangeRate.getDebtProxyAddress(currencyId);
    }

    /// @notice Returns address of the NOTE token
    function getNoteToken() external pure override returns (address) {
        return Deployments.NOTE_TOKEN_ADDRESS;
    }

    /// @notice Returns current ownership status of the contract
    /// @return owner is the current owner of the Notional system
    /// @return pendingOwner can claim ownership from the owner
    function getOwnershipStatus() external view override returns (address, address) {
        return (owner, pendingOwner);
    }

    function getGlobalTransferOperatorStatus(address operator) external view override returns (bool isAuthorized) {
        return globalTransferOperator[operator];
    }

    function getAuthorizedCallbackContractStatus(address callback) external view override returns (bool isAuthorized) {
        return authorizedCallbackContract[callback];
    }

    function getSecondaryIncentiveRewarder(uint16 currencyId) external view override returns (address rewarder) {
        address tokenAddress = nTokenHandler.nTokenAddress(currencyId);
        return address(nTokenHandler.getSecondaryRewarder(tokenAddress));
    }

    /** Global System State View Methods **/
    function getPrimeFactors(
        uint16 currencyId,
        uint256 blockTime
    ) external view override returns (
        PrimeRate memory pr,
        PrimeCashFactors memory factors,
        uint256 maxUnderlyingSupply,
        uint256 totalUnderlyingSupply
    ) {
        (pr, factors) = PrimeCashExchangeRate.getPrimeCashRateView(currencyId, blockTime);
        (maxUnderlyingSupply, totalUnderlyingSupply) = pr.getSupplyCap(currencyId);
    }

    function getPrimeFactorsStored(
        uint16 currencyId
    ) external view override returns (PrimeCashFactors memory) {
        return PrimeCashExchangeRate.getPrimeCashFactors(currencyId);
    }

    function getPrimeCashHoldingsOracle(uint16 currencyId) external view override returns (address) {
        return address(PrimeCashExchangeRate.getPrimeCashHoldingsOracle(currencyId));
    }

    function getPrimeInterestRateCurve(uint16 currencyId) external view override returns (
        InterestRateParameters memory
    ) {
        return InterestRateCurve.getPrimeCashInterestRateParameters(currencyId);
    }

    function getTotalfCashDebtOutstanding(
        uint16 currencyId, uint256 maturity
    ) external view override returns (
        int256 totalfCashDebt,
        int256 fCashDebtHeldInSettlementReserve,
        int256 primeCashHeldInSettlementReserve
    ) {
        mapping(uint256 => mapping(uint256 => TotalfCashDebtStorage)) storage store = LibStorage.getTotalfCashDebtOutstanding();
        TotalfCashDebtStorage storage s = store[currencyId][maturity];
        totalfCashDebt =  -int256(s.totalfCashDebt);
        fCashDebtHeldInSettlementReserve =  -int256(s.fCashDebtHeldInSettlementReserve);
        primeCashHeldInSettlementReserve = int256(s.primeCashHeldInSettlementReserve);
    }

    /// @notice Returns the asset settlement rate for a given maturity
    function getSettlementRate(uint16 currencyId, uint40 maturity)
        external view override returns (PrimeRate memory) {
        _checkValidCurrency(currencyId);
        return PrimeRateLib.buildPrimeRateSettlementView(
            currencyId, maturity, block.timestamp
        );
    }

    /// @notice Returns a single market
    function getMarket(
        uint16 currencyId,
        uint256 maturity,
        uint256 settlementDate
    )
        external
        view
        override
        returns (MarketParameters memory)
    {
        _checkValidCurrency(currencyId);
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        MarketParameters memory market;
        market.loadMarketWithSettlementDate(
            currencyId,
            maturity,
            block.timestamp,
            true,
            cashGroup.getRateOracleTimeWindow(),
            settlementDate
        );

        return market;
    }

    /// @notice Returns all currently active markets for a currency
    function getActiveMarkets(uint16 currencyId)
        external
        view
        override
        returns (MarketParameters[] memory)
    {
        _checkValidCurrency(currencyId);
        return _getActiveMarketsAtBlockTime(currencyId, block.timestamp);
    }

    /// @notice Returns all active markets for a currency at the specified block time, useful for looking
    /// at historical markets
    function getActiveMarketsAtBlockTime(uint16 currencyId, uint32 blockTime)
        external
        view
        override
        returns (MarketParameters[] memory)
    {
        _checkValidCurrency(currencyId);
        return _getActiveMarketsAtBlockTime(currencyId, blockTime);
    }

    function _getActiveMarketsAtBlockTime(uint16 currencyId, uint256 blockTime)
        internal
        view
        returns (MarketParameters[] memory)
    {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        MarketParameters[] memory markets = new MarketParameters[](cashGroup.maxMarketIndex);

        for (uint256 i = 0; i < cashGroup.maxMarketIndex; i++) {
            cashGroup.loadMarket(markets[i], i + 1, true, blockTime);
        }

        return markets;
    }

    /// @notice Returns the current reserve balance for a currency
    function getReserveBalance(uint16 currencyId)
        external
        view
        override
        returns (int256 reserveBalance)
    {
        _checkValidCurrency(currencyId);
        reserveBalance = BalanceHandler.getPositiveCashBalance(Constants.FEE_RESERVE, currencyId);
    }

    function getNTokenPortfolio(address tokenAddress)
        external
        view
        override
        returns (PortfolioAsset[] memory liquidityTokens, PortfolioAsset[] memory netfCashAssets)
    {
        // prettier-ignore
        (
            uint16 currencyId,
            /* incentiveRate */,
            uint256 lastInitializedTime,
            uint8 assetArrayLength,
            /* bytes5 parameters */
        ) = nTokenHandler.getNTokenContext(tokenAddress);

        liquidityTokens = PortfolioHandler.getSortedPortfolio(tokenAddress, assetArrayLength);

        netfCashAssets = BitmapAssetsHandler.getifCashArray(
            tokenAddress,
            currencyId,
            lastInitializedTime
        );
    }

    function getNTokenAccount(address tokenAddress)
        external
        view
        override
        returns (
            uint16 currencyId,
            uint256 totalSupply,
            uint256 incentiveAnnualEmissionRate,
            uint256 lastInitializedTime,
            bytes5 nTokenParameters,
            int256 cashBalance,
            uint256 accumulatedNOTEPerNToken,
            uint256 lastAccumulatedTime
        )
    {
        (
            currencyId,
            incentiveAnnualEmissionRate,
            lastInitializedTime,
            /* assetArrayLength */,
            nTokenParameters
        ) = nTokenHandler.getNTokenContext(tokenAddress);

        // prettier-ignore
        (
            totalSupply,
            accumulatedNOTEPerNToken,
            lastAccumulatedTime
        ) = nTokenSupply.getStoredNTokenSupplyFactors(tokenAddress);

        // prettier-ignore
        (
            cashBalance,
            /* */,
            /* */,
            /* */
        ) = BalanceHandler.getBalanceStorageView(tokenAddress, currencyId, block.timestamp);
    }

    /** Account Specific View Methods **/

    /// @notice Returns all account details in a single view
    function getAccount(address account)
        external
        view
        override
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
            ) = BalanceHandler.getBalanceStorageView(account, accountContext.bitmapCurrencyId, block.timestamp);
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
            ) = BalanceHandler.getBalanceStorageView(account, b.currencyId, block.timestamp);
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

    /// @notice Returns account context
    function getAccountContext(address account) external view override returns (AccountContext memory) {
        return AccountContextHandler.getAccountContext(account);
    }

    function getAccountPrimeDebtBalance(uint16 currencyId, address account) external view override returns (
        int256 debtBalance
    ) {
        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage.getBalanceStorage();
        BalanceStorage storage balanceStorage = store[account][currencyId];
        int256 cashBalance = balanceStorage.cashBalance;

        // Only return cash balances less than zero
        debtBalance = cashBalance < 0 ? cashBalance : 0;
    }

    /// @notice Returns account balances for a given currency
    function getAccountBalance(uint16 currencyId, address account) external view override returns (
        int256 cashBalance,
        int256 nTokenBalance,
        uint256 lastClaimTime
    ) {
        _checkValidCurrency(currencyId);
        // prettier-ignore
        (
            cashBalance,
            nTokenBalance,
            lastClaimTime,
            /* */
        ) = BalanceHandler.getBalanceStorageView(account, currencyId, block.timestamp);
    }

    /// @notice Returns the balance of figure for prime cash for the prime cash proxy, the logic is slightly modified
    /// for the nToken account because it needs to return the sum of all cash held in markets.
    function getBalanceOfPrimeCash(
        uint16 currencyId,
        address account
    ) external view override returns (int256 cashBalance) {
        (cashBalance, /* */, /* */, /* */) = BalanceHandler.getBalanceStorageView(account, currencyId, block.timestamp);

        if (account == nTokenHandler.nTokenAddress(currencyId)) {
            MarketParameters[] memory markets = _getActiveMarketsAtBlockTime(currencyId, block.timestamp);
            for (uint256 i; i < markets.length; i++) cashBalance = cashBalance.add(markets[i].totalPrimeCash);
        }
    }

    /// @notice Returns account portfolio of assets
    function getAccountPortfolio(address account) external view override returns (PortfolioAsset[] memory) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        if (accountContext.isBitmapEnabled()) {
            return
                BitmapAssetsHandler.getifCashArray(
                    account,
                    accountContext.bitmapCurrencyId,
                    accountContext.nextSettleTime
                );
        } else {
            return PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength);
        }
    }

    /// @notice Returns the fCash amount at the specified maturity for a bitmapped portfolio
    function getfCashNotional(address account, uint16 currencyId, uint256 maturity) external view override returns (int256) {
        _checkValidCurrency(currencyId);
        return BitmapAssetsHandler.getifCashNotional(account, currencyId, maturity);
    }

    /// @notice Returns the assets bitmap for an account
    function getAssetsBitmap(address account, uint16 currencyId) external view override returns (bytes32) {
        _checkValidCurrency(currencyId);
        return BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
    }

    /// @notice Returns free collateral of an account along with an array of the individual net available
    /// asset cash amounts
    function getFreeCollateral(address account) external view override returns (int256, int256[] memory) {
        return FreeCollateralExternal.getFreeCollateralView(account);
    }

    /// @notice Returns the current treasury manager contract
    function getTreasuryManager() external view override returns (address) {
        return treasuryManagerContract;
    }

    /// @notice Returns the current reserve buffer for a currency
    /// @param currencyId refers to the currency of the reserve
    function getReserveBuffer(uint16 currencyId) external view override returns (uint256) {
        return reserveBuffer[currencyId];
    }

    function getRebalancingTarget(uint16 currencyId, address holding) external view override returns (uint8) {
        mapping(address => uint8) storage rebalancingTargets = LibStorage.getRebalancingTargets()[currencyId];
        return rebalancingTargets[holding];
    }

    function getRebalancingCooldown(uint16 currencyId) external view override returns (uint40) {
        mapping(uint16 => RebalancingContextStorage) storage store = LibStorage.getRebalancingContext();
        return store[currencyId].rebalancingCooldownInSeconds;
    }

    function getStoredTokenBalances(address[] calldata tokens) external view override returns (uint256[] memory balances) {
        mapping(address => uint256) storage store = LibStorage.getStoredTokenBalances();
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = store[tokens[i]];
        }
    }

    function decodeERC1155Id(uint256 id) external view override returns (
        uint16 currencyId,
        uint256 maturity,
        uint256 assetType,
        address vaultAddress,
        bool isfCashDebt
    ) {
        return Emitter.decodeId(id);
    }

    // Encodes an ERC1155 id
    function encode(
        uint16 currencyId,
        uint256 maturity,
        uint256 assetType,
        address vaultAddress,
        bool isfCashDebt
    ) external pure override returns (uint256) {
        return Emitter.encodeId(currencyId, maturity, assetType, vaultAddress, isfCashDebt);
    }

    /// @notice Get a list of deployed library addresses (sorted by library name)
    function getLibInfo() external pure returns (address, address) {
        return (address(FreeCollateralExternal), address(MigrateIncentives));
    }

    fallback() external {
        revert("Method not found");
    }
}
