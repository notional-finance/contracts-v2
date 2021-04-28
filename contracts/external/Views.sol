// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../external/FreeCollateralExternal.sol";
import "./actions/nTokenMintAction.sol";
import "../internal/valuation/ExchangeRate.sol";
import "../internal/markets/CashGroup.sol";
import "../internal/markets/AssetRate.sol";
import "../internal/nTokenHandler.sol";
import "../internal/balances/TokenHandler.sol";
import "../global/StorageLayoutV1.sol";
import "../math/SafeInt256.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";

contract Views is StorageLayoutV1 {
    using CashGroup for CashGroupParameters;
    using TokenHandler for Token;
    using Market for MarketParameters;
    using AssetRate for AssetRateParameters;
    using SafeInt256 for int256;

    function getMaxCurrencyId() external view returns (uint16) {
        return maxCurrencyId;
    }

    function getCurrency(uint16 currencyId) external view returns (Token memory) {
        return TokenHandler.getToken(currencyId, false);
    }

    function getUnderlying(uint16 currencyId) external view returns (Token memory) {
        return TokenHandler.getToken(currencyId, true);
    }

    function getETHRateStorage(uint16 currencyId) external view returns (ETHRateStorage memory) {
        return underlyingToETHRateMapping[currencyId];
    }

    function getETHRate(uint16 currencyId) external view returns (ETHRate memory) {
        return ExchangeRate.buildExchangeRate(currencyId);
    }

    function getCurrencyAndRate(uint16 currencyId)
        external
        view
        returns (Token memory, ETHRate memory)
    {
        return (
            TokenHandler.getToken(currencyId, false),
            ExchangeRate.buildExchangeRate(currencyId)
        );
    }

    function getCashGroup(uint16 currencyId) external view returns (CashGroupSettings memory) {
        return CashGroup.deserializeCashGroupStorage(currencyId);
    }

    function getAssetRateStorage(uint16 currencyId)
        external
        view
        returns (AssetRateStorage memory)
    {
        return assetToUnderlyingRateMapping[currencyId];
    }

    function getAssetRate(uint16 currencyId) external view returns (AssetRateParameters memory) {
        return AssetRate.buildAssetRateView(currencyId);
    }

    function getSettlementRate(uint16 currencyId, uint32 maturity)
        external
        view
        returns (AssetRateParameters memory)
    {
        return AssetRate.buildSettlementRateView(currencyId, maturity);
    }

    function getCashGroupAndRate(uint16 currencyId)
        external
        view
        returns (CashGroupSettings memory, AssetRateParameters memory)
    {
        CashGroupSettings memory cg = CashGroup.deserializeCashGroupStorage(currencyId);
        if (cg.maxMarketIndex == 0) {
            // No markets listed for the currency id
            return (cg, AssetRateParameters(address(0), 0, 0));
        }

        return (cg, AssetRate.buildAssetRateView(currencyId));
    }

    function getActiveMarkets(uint16 currencyId) external view returns (MarketParameters[] memory) {
        uint256 blockTime = block.timestamp;
        return _getActiveMarketsAtBlockTime(currencyId, blockTime);
    }

    function getActiveMarketsAtBlockTime(uint16 currencyId, uint32 blockTime)
        external
        view
        returns (MarketParameters[] memory)
    {
        return _getActiveMarketsAtBlockTime(currencyId, blockTime);
    }

    function _getActiveMarketsAtBlockTime(uint256 currencyId, uint256 blockTime)
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

    function getInitializationParameters(uint16 currencyId)
        external
        view
        returns (int256[] memory, int256[] memory)
    {
        CashGroupSettings memory cg = CashGroup.deserializeCashGroupStorage(currencyId);
        return nTokenHandler.getInitializationParameters(currencyId, cg.maxMarketIndex);
    }

    function getDepositParameters(uint16 currencyId)
        external
        view
        returns (int256[] memory, int256[] memory)
    {
        CashGroupSettings memory cg = CashGroup.deserializeCashGroupStorage(currencyId);
        return nTokenHandler.getDepositParameters(currencyId, cg.maxMarketIndex);
    }

    function nTokenAddress(uint16 currencyId) external view returns (address) {
        return nTokenHandler.nTokenAddress(currencyId);
    }

    function getOwner() external view returns (address) {
        return owner;
    }

    function getAccountContext(address account) external view returns (AccountContext memory) {
        return AccountContextHandler.getAccountContext(account);
    }

    function getAccountBalance(uint16 currencyId, address account)
        external
        view
        returns (
            int256 cashBalance,
            int256 nTokenBalance,
            uint256 lastClaimTime
        )
    {
        // prettier-ignore
        (
            cashBalance,
            nTokenBalance,
            lastClaimTime,
            /* */
        ) = BalanceHandler.getBalanceStorage(account, currencyId);
    }

    function getReserveBalance(uint16 currencyId) external view returns (int256) {
        // prettier-ignore
        (
            int256 cashBalance,
            /* */,
            /* */,
            /* */
        ) = BalanceHandler.getBalanceStorage(Constants.RESERVE, currencyId);
        return cashBalance;
    }

    function getAccountPortfolio(address account) external view returns (PortfolioAsset[] memory) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        if (accountContext.bitmapCurrencyId != 0) {
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

    function getNTokenPortfolio(address tokenAddress)
        external
        view
        returns (PortfolioAsset[] memory, PortfolioAsset[] memory)
    {
        // prettier-ignore
        (
            uint256 currencyId,
            /* uint totalSupply */,
            /* incentiveRate */,
            uint256 lastInitializedTime,
            bytes6 parameters
        ) = nTokenHandler.getNTokenContext(tokenAddress);

        return (
            PortfolioHandler.getSortedPortfolio(
                tokenAddress,
                uint8(parameters[Constants.ASSET_ARRAY_LENGTH])
            ),
            BitmapAssetsHandler.getifCashArray(tokenAddress, currencyId, lastInitializedTime)
        );
    }

    function calculateNTokensToMint(uint16 currencyId, uint88 amountToDepositExternalPrecision)
        external
        view
        returns (uint256)
    {
        Token memory token = TokenHandler.getToken(currencyId, false);
        int256 amountToDepositInternal =
            token.convertToInternal(int256(amountToDepositExternalPrecision));
        nTokenPortfolio memory nToken;
        nTokenHandler.loadNTokenPortfolioView(currencyId, nToken);

        // prettier-ignore
        (
            int256 tokensToMint,
            /* */
        ) = nTokenMintAction.calculateTokensToMint(
            nToken,
            amountToDepositInternal,
            block.timestamp
        );

        return SafeCast.toUint256(tokensToMint);
    }

    function getifCashNotional(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) external view returns (int256) {
        bytes32 fCashSlot = BitmapAssetsHandler.getifCashSlot(account, currencyId, maturity);
        int256 notional;
        assembly {
            notional := sload(fCashSlot)
        }
        return notional;
    }

    function getifCashBitmap(address account, uint256 currencyId) external view returns (bytes32) {
        return BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
    }

    function getFreeCollateralView(address account)
        external
        view
        returns (int256, int256[] memory)
    {
        return FreeCollateralExternal.getFreeCollateralView(account);
    }

    function getfCashAmountGivenCashAmount(
        uint16 currencyId,
        int88 netCashToAccount,
        uint256 marketIndex,
        uint256 blockTime
    ) external view returns (int256) {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        MarketParameters memory market;
        cashGroup.loadMarket(market, marketIndex, false, blockTime);

        require(market.maturity > blockTime, "Error");
        uint256 timeToMaturity = market.maturity - blockTime;
        (int256 rateScalar, int256 totalCashUnderlying, int256 rateAnchor) =
            Market.getExchangeRateFactors(market, cashGroup, timeToMaturity, marketIndex);
        require(rateScalar > 0, "Error");
        int256 fee = Market.getExchangeRateFromImpliedRate(cashGroup.getTotalFee(), timeToMaturity);

        return
            Market.getfCashGivenCashAmount(
                market.totalfCash,
                int256(netCashToAccount),
                totalCashUnderlying,
                rateScalar,
                rateAnchor,
                fee,
                0
            );
    }

    function getCashAmountGivenfCashAmount(
        uint16 currencyId,
        int88 fCashAmount,
        uint256 marketIndex,
        uint256 blockTime
    ) external view returns (int256, int256) {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        MarketParameters memory market;
        cashGroup.loadMarket(market, marketIndex, false, blockTime);

        require(market.maturity > blockTime, "Error");
        uint256 timeToMaturity = market.maturity - blockTime;

        // prettier-ignore
        (int256 assetCash, /* int fee */) =
            market.calculateTrade(cashGroup, fCashAmount, timeToMaturity, marketIndex);

        return (assetCash, cashGroup.assetRate.convertToUnderlying(assetCash));
    }

    fallback() external {
        revert("Method not found");
    }
}
