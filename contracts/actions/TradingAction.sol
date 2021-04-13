// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../external/FreeCollateralExternal.sol";
import "./SettleAssetsExternal.sol";
import "./DepositWithdrawAction.sol";
import "../math/SafeInt256.sol";
import "../internal/markets/Market.sol";
import "../internal/markets/CashGroup.sol";
import "../internal/markets/AssetRate.sol";
import "../internal/balances/BalanceHandler.sol";
import "../internal/portfolio/PortfolioHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library TradingAction {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;
    using Market for MarketParameters;
    using CashGroup for CashGroupParameters;
    using AssetRate for AssetRateParameters;
    using SafeInt256 for int256;
    using SafeMath for uint256;

    event BatchTradeExecution(address account, uint16 currencyId);

    struct BitmapTradeContext {
        int256 cash;
        int256 fCashAmount;
        int256 fee;
        int256 netCash;
        int256 totalFee;
        uint256 blockTime;
    }

    function executeTradesBitmapBatch(
        address account,
        AccountStorage calldata accountContext,
        bytes32[] calldata trades
    ) external returns (int256, bool) {
        (CashGroupParameters memory cashGroup, MarketParameters[] memory markets) =
            CashGroup.buildCashGroupStateful(accountContext.bitmapCurrencyId);
        bytes32 ifCashBitmap =
            BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId);
        bool didIncurDebt;
        BitmapTradeContext memory c;
        c.blockTime = block.timestamp;

        for (uint256 i; i < trades.length; i++) {
            uint256 maturity;
            (maturity, c.cash, c.fCashAmount, c.fee) = _executeTrade(
                account,
                cashGroup,
                markets,
                trades[i],
                c.blockTime
            );

            (ifCashBitmap, c.fCashAmount) = BitmapAssetsHandler.addifCashAsset(
                account,
                accountContext.bitmapCurrencyId,
                maturity,
                accountContext.nextSettleTime,
                c.fCashAmount,
                ifCashBitmap
            );

            if (c.fCashAmount < 0) didIncurDebt = true;
            c.netCash = c.netCash.add(c.cash);
            c.totalFee = c.totalFee.add(c.fee);
        }

        BitmapAssetsHandler.setAssetsBitmap(account, accountContext.bitmapCurrencyId, ifCashBitmap);
        emit BatchTradeExecution(account, uint16(accountContext.bitmapCurrencyId));
        BalanceHandler.incrementFeeToReserve(accountContext.bitmapCurrencyId, c.totalFee);

        return (c.netCash, didIncurDebt);
    }

    function executeTradesArrayBatch(
        address account,
        uint256 currencyId,
        PortfolioState memory portfolioState,
        bytes32[] calldata trades
    ) external returns (PortfolioState memory, int256) {
        uint256 blockTime = block.timestamp;
        (CashGroupParameters memory cashGroup, MarketParameters[] memory markets) =
            CashGroup.buildCashGroupStateful(currencyId);
        int256[] memory values = new int256[](4);

        for (uint256 i; i < trades.length; i++) {
            TradeActionType tradeType = TradeActionType(uint256(uint8(bytes1(trades[i]))));

            if (
                tradeType == TradeActionType.AddLiquidity ||
                tradeType == TradeActionType.RemoveLiquidity
            ) {
                // cashAmount
                values[2] = _executeLiquidityTrade(
                    cashGroup,
                    tradeType,
                    trades[i],
                    portfolioState,
                    values[0]
                );
            } else {
                uint256 maturity;
                int256 fee;
                // (maturity, cashAmount, fCashAmount, fee)
                (maturity, values[2], values[3], fee) = _executeTrade(
                    account,
                    cashGroup,
                    markets,
                    trades[i],
                    blockTime
                );
                // Stack issues here :(
                _addfCashAsset(portfolioState, currencyId, maturity, values[3]);
                values[1] = values[1].add(fee);
            }

            // netCash = netCash + cashAmount
            values[0] = values[0].add(values[2]);
        }

        emit BatchTradeExecution(account, uint16(currencyId));
        BalanceHandler.incrementFeeToReserve(currencyId, values[1]);

        return (portfolioState, values[0]);
    }

    function _addfCashAsset(
        PortfolioState memory portfolioState,
        uint256 currencyId,
        uint256 maturity,
        int256 notional
    ) internal pure {
        portfolioState.addAsset(currencyId, maturity, Constants.FCASH_ASSET_TYPE, notional, false);
    }

    function _executeTrade(
        address account,
        CashGroupParameters memory cashGroup,
        // TODO: refactor this to get rid of the markets array
        MarketParameters[] memory markets,
        bytes32 trade,
        uint256 blockTime
    )
        internal
        returns (
            uint256,
            int256,
            int256,
            int256
        )
    {
        TradeActionType tradeType = TradeActionType(uint256(uint8(bytes1(trade))));

        uint256 maturity;
        int256 cashAmount;
        int256 fCashAmount;
        int256 fee;
        if (tradeType == TradeActionType.PurchasePerpetualTokenResidual) {
            (maturity, cashAmount, fCashAmount) = _purchasePerpetualTokenResidual(
                cashGroup,
                markets,
                blockTime,
                trade
            );
        } else if (tradeType == TradeActionType.SettleCashDebt) {
            // Settling debts will use the oracle rate from the 3 month market
            (maturity, cashAmount, fCashAmount) = _settleCashDebt(
                cashGroup,
                markets,
                blockTime,
                trade
            );
        } else if (tradeType == TradeActionType.Lend || tradeType == TradeActionType.Borrow) {
            (maturity, cashAmount, fCashAmount, fee) = _executeLendBorrowTrade(
                cashGroup,
                tradeType,
                blockTime,
                trade
            );
        } else {
            revert("Invalid trade type");
        }

        return (maturity, cashAmount, fCashAmount, fee);
    }

    function _loadMarket(
        MarketParameters memory market,
        CashGroupParameters memory cashGroup,
        uint256 marketIndex,
        bool needsLiquidity
    ) internal view {
        require(marketIndex <= cashGroup.maxMarketIndex, "Invalid market");
        uint256 blockTime = block.timestamp;
        uint256 maturity =
            CashGroup.getReferenceTime(blockTime).add(CashGroup.getTradedMarket(marketIndex));
        market.loadMarket(
            cashGroup.currencyId,
            maturity,
            blockTime,
            needsLiquidity,
            cashGroup.getRateOracleTimeWindow()
        );
    }

    function _executeLiquidityTrade(
        CashGroupParameters memory cashGroup,
        TradeActionType tradeType,
        bytes32 trade,
        PortfolioState memory portfolioState,
        int256 netCash
    ) internal returns (int256) {
        uint256 marketIndex = uint256(uint8(bytes1(trade << 8)));
        // TODO: refactor this to get rid of the markets array
        MarketParameters memory market;
        _loadMarket(market, cashGroup, marketIndex, true);

        int256 cashAmount;
        int256 fCashAmount;
        int256 tokens;
        if (tradeType == TradeActionType.AddLiquidity) {
            cashAmount = int256(uint88(bytes11(trade << 16)));
            // Setting cash amount to zero will deposit all net cash accumulated in this trade into
            // liquidity. This feature allows accounts to borrow in one maturity to provide liquidity
            // in another in a single transaction without dust. It also allows liquidity providers to
            // sell off the net cash residuals and use the cash amount in the new market without dust
            if (cashAmount == 0) {
                cashAmount = netCash;
                require(cashAmount > 0, "Invalid cash roll");
            }

            (tokens, fCashAmount) = market.addLiquidity(cashAmount);
            cashAmount = cashAmount.neg(); // Net cash is negative
        } else {
            tokens = int256(uint88(bytes11(trade << 16)));
            (cashAmount, fCashAmount) = market.removeLiquidity(tokens);
            tokens = tokens.neg();
        }

        {
            uint256 minImpliedRate = uint256(uint32(bytes4(trade << 104)));
            uint256 maxImpliedRate = uint256(uint32(bytes4(trade << 136)));
            require(market.lastImpliedRate >= minImpliedRate, "Trade failed, slippage");
            if (maxImpliedRate != 0)
                require(market.lastImpliedRate <= maxImpliedRate, "Trade failed, slippage");
            market.setMarketStorage();
        }

        // Add the assets in this order so they are sorted
        portfolioState.addAsset(
            cashGroup.currencyId,
            market.maturity,
            Constants.FCASH_ASSET_TYPE,
            fCashAmount,
            false
        );
        portfolioState.addAsset(
            cashGroup.currencyId,
            market.maturity,
            marketIndex + 1,
            tokens,
            false
        );

        return (cashAmount);
    }

    function _executeLendBorrowTrade(
        CashGroupParameters memory cashGroup,
        TradeActionType tradeType,
        uint256 blockTime,
        bytes32 trade
    )
        internal
        returns (
            uint256,
            int256,
            int256,
            int256
        )
    {
        uint256 marketIndex = uint256(uint8(bytes1(trade << 8)));
        MarketParameters memory market;
        _loadMarket(market, cashGroup, marketIndex, false);

        int256 fCashAmount = int256(uint88(bytes11(trade << 16)));
        if (tradeType == TradeActionType.Borrow) {
            fCashAmount = fCashAmount.neg();
        }

        (int256 cashAmount, int256 fee) =
            market.calculateTrade(
                cashGroup,
                fCashAmount,
                market.maturity.sub(blockTime),
                marketIndex
            );
        require(cashAmount != 0, "Trade failed");

        uint256 rateLimit = uint256(uint32(bytes4(trade << 104)));
        if (rateLimit != 0) {
            if (tradeType == TradeActionType.Borrow) {
                require(market.lastImpliedRate <= rateLimit, "Trade failed, slippage");
            } else {
                require(market.lastImpliedRate >= rateLimit, "Trade failed, slippage");
            }
        }
        market.setMarketStorage();

        return (market.maturity, cashAmount, fCashAmount, fee);
    }

    function _settleCashDebt(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint256 blockTime,
        bytes32 trade
    )
        internal
        returns (
            uint256,
            int256,
            int256
        )
    {
        address counterparty = address(bytes20(trade << 8));
        int256 amountToSettleAsset = int256(int88(bytes11(trade << 168)));

        AccountStorage memory counterpartyContext =
            AccountContextHandler.getAccountContext(counterparty);

        if (counterpartyContext.mustSettleAssets()) {
            counterpartyContext = SettleAssetsExternal.settleAssetsAndFinalize(counterparty);
        }

        // This will check if the amountToSettleAsset is valid and revert if it is not. Amount to settle is a positive
        // number denominated in asset terms. If amountToSettleAsset is set equal to zero on the input, will return the
        // max amount to settle.
        amountToSettleAsset = BalanceHandler.setBalanceStorageForSettleCashDebt(
            counterparty,
            cashGroup,
            amountToSettleAsset,
            counterpartyContext
        );

        // Settled account must borrow from the 3 month market at a penalty rate. Even if the market is
        // not initialized we can still settle cash debts because we reference the previous 3 month market's oracle
        // rate which is where the new 3 month market's oracle rate will be initialized to.
        uint256 threeMonthMaturity = CashGroup.getReferenceTime(blockTime) + Constants.QUARTER;
        int256 fCashAmount =
            _getfCashSettleAmount(
                cashGroup,
                markets,
                threeMonthMaturity,
                blockTime,
                amountToSettleAsset
            );

        // It's possible that this action will put an account into negative free collateral. In this case they
        // will immediately become eligible for liquidation and the account settling the debt can also liquidate
        // them in the same transaction. Do not run a free collateral check here to allow this to happen.
        placefCashAssetInCounterparty(
            counterparty,
            counterpartyContext,
            cashGroup.currencyId,
            threeMonthMaturity,
            fCashAmount.neg() // This is the debt the settled account will incur
        );
        counterpartyContext.setAccountContext(counterparty);

        return (threeMonthMaturity, amountToSettleAsset.neg(), fCashAmount);
    }

    function _getfCashSettleAmount(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint256 threeMonthMaturity,
        uint256 blockTime,
        int256 amountToSettleAsset
    ) internal view returns (int256) {
        uint256 oracleRate = cashGroup.getOracleRate(markets, threeMonthMaturity, blockTime);

        int256 exchangeRate =
            Market.getExchangeRateFromImpliedRate(
                oracleRate.add(cashGroup.getSettlementPenalty()),
                threeMonthMaturity.sub(blockTime)
            );

        // Amount to settle is positive, this returns the fCashAmount that the settler will
        // receive as a positive number
        return
            cashGroup.assetRate.convertToUnderlying(amountToSettleAsset).mul(exchangeRate).div(
                Constants.RATE_PRECISION
            );
    }

    function _purchasePerpetualTokenResidual(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint256 blockTime,
        bytes32 trade
    )
        internal
        returns (
            uint256,
            int256,
            int256
        )
    {
        uint256 maturity = uint256(uint32(bytes4(trade << 8)));
        int256 fCashAmountToPurchase = int256(int88(bytes11(trade << 40)));
        require(maturity > blockTime, "Invalid maturity");
        // Require that the residual to purchase does not fall on an existing maturity (i.e.
        // it is an idiosyncratic maturity)
        require(!cashGroup.isValidMaturity(maturity, blockTime), "Invalid maturity");

        address perpTokenAddress = PerpetualToken.nTokenAddress(cashGroup.currencyId);
        (
            ,
            ,
            ,
            /* currencyId */
            /* totalSupply */
            /* incentiveRate */
            uint256 lastInitializedTime,
            bytes6 parameters
        ) = PerpetualToken.getPerpetualTokenContext(perpTokenAddress);

        require(
            blockTime >
                lastInitializedTime.add(
                    uint256(uint8(parameters[PerpetualToken.RESIDUAL_PURCHASE_TIME_BUFFER])) * 3600
                ),
            "Insufficient block time"
        );

        int256 notional =
            BitmapAssetsHandler.getifCashNotional(perpTokenAddress, cashGroup.currencyId, maturity);
        if (notional < 0 && fCashAmountToPurchase < 0) {
            if (fCashAmountToPurchase < notional) fCashAmountToPurchase = notional;
        } else if (notional > 0 && fCashAmountToPurchase > 0) {
            if (fCashAmountToPurchase > notional) fCashAmountToPurchase = notional;
        } else {
            revert("Invalid amount");
        }

        int256 netAssetCashPerpToken =
            getResidualPrice(
                cashGroup,
                markets,
                maturity,
                blockTime,
                fCashAmountToPurchase,
                parameters
            );

        updatePerpTokenPortfolio(
            perpTokenAddress,
            cashGroup,
            maturity,
            lastInitializedTime,
            fCashAmountToPurchase,
            netAssetCashPerpToken
        );

        return (maturity, netAssetCashPerpToken.neg(), fCashAmountToPurchase);
    }

    function getResidualPrice(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint256 maturity,
        uint256 blockTime,
        int256 fCashAmount,
        bytes6 parameters
    ) internal view returns (int256) {
        uint256 oracleRate = cashGroup.getOracleRate(markets, maturity, blockTime);
        uint256 purchaseIncentive =
            uint256(uint8(parameters[PerpetualToken.RESIDUAL_PURCHASE_INCENTIVE])) *
                10 *
                Constants.BASIS_POINT;

        if (fCashAmount > 0) {
            oracleRate = oracleRate.add(purchaseIncentive);
        } else if (oracleRate > purchaseIncentive) {
            oracleRate = oracleRate.sub(purchaseIncentive);
        } else {
            // If the oracle rate is less than the purchase incentive floor the interest rate at zero
            oracleRate = 0;
        }

        int256 exchangeRate =
            Market.getExchangeRateFromImpliedRate(oracleRate, maturity.sub(blockTime));
        return
            cashGroup.assetRate.convertFromUnderlying(
                fCashAmount.mul(Constants.RATE_PRECISION).div(exchangeRate)
            );
    }

    function updatePerpTokenPortfolio(
        address perpTokenAddress,
        CashGroupParameters memory cashGroup,
        uint256 maturity,
        uint256 lastInitializedTime,
        int256 fCashAmountToPurchase,
        int256 netAssetCashPerpToken
    ) private {
        bytes32 ifCashBitmap =
            BitmapAssetsHandler.getAssetsBitmap(perpTokenAddress, cashGroup.currencyId);
        (
            ifCashBitmap, /* notional */

        ) = BitmapAssetsHandler.addifCashAsset(
            perpTokenAddress,
            cashGroup.currencyId,
            maturity,
            lastInitializedTime,
            fCashAmountToPurchase.neg(),
            ifCashBitmap
        );
        BitmapAssetsHandler.setAssetsBitmap(perpTokenAddress, cashGroup.currencyId, ifCashBitmap);

        (int256 perpTokenCashBalance, , ) =
            /* perpToken.balanceState.storedPerpetualTokenBalance */
            /* lastIncentiveClaim */
            BalanceHandler.getBalanceStorage(perpTokenAddress, cashGroup.currencyId);
        perpTokenCashBalance = perpTokenCashBalance.add(netAssetCashPerpToken);
        // This will ensure that the cash balance is not negative
        BalanceHandler.setBalanceStorageForNToken(
            perpTokenAddress,
            cashGroup.currencyId,
            perpTokenCashBalance
        );
    }

    function placefCashAssetInCounterparty(
        address counterparty,
        AccountStorage memory counterpartyContext,
        uint256 currencyId,
        uint256 maturity,
        int256 fCashAmount
    ) internal {
        if (counterpartyContext.bitmapCurrencyId != 0) {
            require(counterpartyContext.bitmapCurrencyId == currencyId, "Invalid cash pair");
            bytes32 ifCashBitmap = BitmapAssetsHandler.getAssetsBitmap(counterparty, currencyId);
            int256 notional;
            (ifCashBitmap, notional) = BitmapAssetsHandler.addifCashAsset(
                counterparty,
                currencyId,
                maturity,
                counterpartyContext.nextSettleTime,
                fCashAmount,
                ifCashBitmap
            );
            if (notional < 0)
                counterpartyContext.hasDebt =
                    counterpartyContext.hasDebt |
                    AccountContextHandler.HAS_ASSET_DEBT;
            BitmapAssetsHandler.setAssetsBitmap(counterparty, currencyId, ifCashBitmap);
        } else {
            PortfolioState memory portfolioState =
                PortfolioHandler.buildPortfolioState(
                    counterparty,
                    counterpartyContext.assetArrayLength,
                    1
                );
            portfolioState.addAsset(
                currencyId,
                maturity,
                Constants.FCASH_ASSET_TYPE,
                fCashAmount,
                false
            );
            counterpartyContext.storeAssetsAndUpdateContext(counterparty, portfolioState);
        }
    }
}
