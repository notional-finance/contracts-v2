// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./FreeCollateralExternal.sol";
import "./SettleAssetsExternal.sol";
import "./DepositWithdrawAction.sol";
import "../math/SafeInt256.sol";
import "../common/Market.sol";
import "../common/CashGroup.sol";
import "../common/AssetRate.sol";
import "../storage/BalanceHandler.sol";
import "../storage/SettleAssets.sol";
import "../storage/PortfolioHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

enum TradeActionType {
    // (uint8, uint8, uint88, uint32)
    Lend,
    // (uint8, uint8, uint88, uint32)
    Borrow,
    // (uint8, uint8, uint88, uint32, uint32)
    AddLiquidity,
    // (uint8, uint8, uint88, uint32, uint32)
    RemoveLiquidity,
    // (uint8, address, uint32, int56)
    MintCashPair,
    // (uint8, uint32, int88)
    PurchasePerpetualTokenResidual,
    // (uint8, address, int88)
    SettleCashDebt
}

library TradingAction {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;
    using Market for MarketParameters;
    using CashGroup for CashGroupParameters;
    using AssetRate for AssetRateParameters;
    using SafeInt256 for int;
    using SafeMath for uint;

    event BatchTradeExecution(address account, uint16 currencyId);

    function executeTradesBitmapBatch(
        address account,
        uint currencyId,
        bytes32[] calldata trades
    ) external returns (int) {
        uint blockTime = block.timestamp;
        (
            CashGroupParameters memory cashGroup,
            MarketParameters[] memory markets
        ) = CashGroup.buildCashGroupStateful(currencyId);
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        bytes32 ifCashBitmap = BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
        int[] memory values = new int[](4);

        for (uint i; i < trades.length; i++) {
            uint maturity;
            int fCashAmount;
            (
                maturity,
                values[2], // cash amount
                fCashAmount,
                values[3] // fee
            ) = _executeTrade(account, cashGroup, markets, trades[i], blockTime);

            ifCashBitmap = BitmapAssetsHandler.setifCashAsset(
                account,
                currencyId,
                maturity,
                accountContext.nextSettleTime,
                fCashAmount,
                ifCashBitmap
            );
            // netCash = netCash + cashAmount
            values[0] = values[0].add(values[2]);
            // totalFee = totalFee + fee
            values[1] = values[1].add(values[3]);
        }

        BitmapAssetsHandler.setAssetsBitmap(account, currencyId, ifCashBitmap);
        emit BatchTradeExecution(account, uint16(currencyId));
        BalanceHandler.incrementFeeToReserve(currencyId, values[1]);

        return (values[0]);
    }

    function executeTradesArrayBatch(
        address account,
        uint currencyId,
        PortfolioState memory portfolioState,
        bytes32[] calldata trades
    ) external returns (PortfolioState memory, int) {
        uint blockTime = block.timestamp;
        (
            CashGroupParameters memory cashGroup,
            MarketParameters[] memory markets
        ) = CashGroup.buildCashGroupStateful(currencyId);
        int[] memory values = new int[](4);

        for (uint i; i < trades.length; i++) {
            TradeActionType tradeType = TradeActionType(uint(uint8(bytes1(trades[i]))));

            if (tradeType == TradeActionType.AddLiquidity || tradeType == TradeActionType.RemoveLiquidity) {
                // cashAmount
                values[2] = _executeLiquidityTrade(cashGroup, tradeType, trades[i], portfolioState, values[0]);
            } else {
                uint maturity;
                int fee;
                // (maturity, cashAmount, fCashAmount, fee)
                (maturity, values[2], values[3], fee) = _executeTrade(account, cashGroup, markets, trades[i], blockTime);
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
        uint currencyId,
        uint maturity,
        int notional
    ) internal pure {
        portfolioState.addAsset(currencyId, maturity, AssetHandler.FCASH_ASSET_TYPE, notional, false);
    }

    function _executeTrade(
        address account,
        CashGroupParameters memory cashGroup,
        // TODO: refactor this to get rid of the markets array
        MarketParameters[] memory markets,
        bytes32 trade,
        uint blockTime
    ) internal returns (uint, int, int, int) {
        TradeActionType tradeType = TradeActionType(uint(uint8(bytes1(trade))));

        uint maturity;
        int cashAmount;
        int fCashAmount;
        int fee;
        if (tradeType == TradeActionType.MintCashPair) {
            (maturity, fCashAmount) = _mintCashPair(account, cashGroup, blockTime, trade);
        } else if (tradeType == TradeActionType.PurchasePerpetualTokenResidual) {
            (maturity, cashAmount, fCashAmount) = _purchasePerpetualTokenResidual(cashGroup, markets, blockTime, trade);
        } else if (tradeType == TradeActionType.SettleCashDebt) {
            // Settling debts will use the oracle rate from the 3 month market
            (maturity, cashAmount, fCashAmount) = _settleCashDebt(cashGroup, markets, blockTime, trade);
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
        uint marketIndex,
        bool needsLiquidity
    ) internal view {
        require(marketIndex <= cashGroup.maxMarketIndex, "Invalid market");
        uint blockTime = block.timestamp;
        uint maturity = CashGroup.getReferenceTime(blockTime).add(CashGroup.getTradedMarket(marketIndex));
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
        int netCash
    ) internal returns (int) {
        uint marketIndex = uint(uint8(bytes1(trade << 8)));
        // TODO: refactor this to get rid of the markets array
        MarketParameters memory market;
        _loadMarket(market, cashGroup, marketIndex, true);

        int cashAmount;
        int fCashAmount;
        int tokens;
        if (tradeType == TradeActionType.AddLiquidity) {
            cashAmount = int(uint88(bytes11(trade << 16)));
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
            tokens = int(uint88(bytes11(trade << 16)));
            (cashAmount, fCashAmount) = market.removeLiquidity(tokens);
            tokens = tokens.neg();
        }

        {
            uint minImpliedRate = uint(uint32(bytes4(trade << 104)));
            uint maxImpliedRate = uint(uint32(bytes4(trade << 136)));
            require(market.lastImpliedRate >= minImpliedRate, "Trade failed, slippage");
            if (maxImpliedRate != 0) require(market.lastImpliedRate <= maxImpliedRate, "Trade failed, slippage");
            market.setMarketStorage();
        }

        // Add the assets in this order so they are sorted
        portfolioState.addAsset(cashGroup.currencyId, market.maturity, AssetHandler.FCASH_ASSET_TYPE, fCashAmount, false);
        portfolioState.addAsset(cashGroup.currencyId, market.maturity, marketIndex + 1, tokens, false);

        return (cashAmount);
    }

    function _executeLendBorrowTrade(
        CashGroupParameters memory cashGroup,
        TradeActionType tradeType,
        uint blockTime,
        bytes32 trade
    ) internal returns (uint, int, int, int) {
        uint marketIndex = uint(uint8(bytes1(trade << 8)));
        MarketParameters memory market;
        _loadMarket(market, cashGroup, marketIndex, false);

        int fCashAmount = int(uint88(bytes11(trade << 16)));
        if (tradeType == TradeActionType.Borrow) {
            fCashAmount = fCashAmount.neg();
        }

        (
            int cashAmount,
            int fee
        ) = market.calculateTrade(
            cashGroup,
            fCashAmount,
            market.maturity.sub(blockTime),
            marketIndex
        );
        require(cashAmount != 0, "Trade failed");

        uint rateLimit = uint(uint32(bytes4(trade << 104)));
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
        uint blockTime,
        bytes32 trade
    ) internal returns (uint, int, int) {
        address counterparty = address(bytes20(trade << 8));
        int amountToSettle = int(int88(bytes11(trade << 168)));

        AccountStorage memory counterpartyContext = AccountContextHandler.getAccountContext(counterparty);
        if (counterpartyContext.mustSettleAssets()) {
            counterpartyContext = SettleAssetsExternal.settleAssetsAndFinalize(counterparty);
        }

        // This will check if the amountToSettle is valid and revert if it is not. Amount to settle is a positive
        // number denominated in underlying terms. If amountToSettle is set equal to zero on the input, will return the
        // max amount to settle.
        int netAssetCashToSettler;
        (
            amountToSettle,
            netAssetCashToSettler
        ) = BalanceHandler.setBalanceStorageForSettleCashDebt(
            counterparty,
            cashGroup,
            amountToSettle,
            counterpartyContext
        );

        // Settled account must borrow from the 3 month market at a penalty rate. Even if the market is
        // not initialized we can still settle cash debts because we reference the previous 3 month market's oracle
        // rate which is where the new 3 month market's oracle rate will be initialized to.
        uint threeMonthMaturity = CashGroup.getReferenceTime(blockTime) + CashGroup.QUARTER;
        int fCashAmount = _getfCashSettleAmount(cashGroup, markets, threeMonthMaturity, blockTime, amountToSettle);

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

        return (threeMonthMaturity, netAssetCashToSettler, fCashAmount);
    }

    function _getfCashSettleAmount(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint threeMonthMaturity,
        uint blockTime,
        int amountToSettle
    ) internal view returns (int) {
        uint oracleRate = cashGroup.getOracleRate(markets, threeMonthMaturity, blockTime);

        int exchangeRate = Market.getExchangeRateFromImpliedRate(
            oracleRate.add(cashGroup.getSettlementPenalty()),
            threeMonthMaturity.sub(blockTime)
        );
        // Amount to settle is positive, this returns the fCashAmount that the settler will
        // receive as a positive number
        return amountToSettle.mul(exchangeRate).div(Market.RATE_PRECISION);
    }

    function _purchasePerpetualTokenResidual(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint blockTime,
        bytes32 trade
    ) internal returns (uint, int, int) {
        uint maturity = uint(uint32(bytes4(trade << 8)));
        int fCashAmountToPurchase = int(int88(bytes11(trade << 40)));
        require(maturity > blockTime, "Invalid maturity");
        // Require that the residual to purchase does not fall on an existing maturity (i.e.
        // it is an idiosyncratic maturity)
        require(!cashGroup.isValidMaturity(maturity, blockTime), "Invalid maturity");

        address perpTokenAddress = PerpetualToken.getPerpetualTokenAddress(cashGroup.currencyId);
        (
            /* currencyId */,
            /* totalSupply */,
            /* incentiveRate */,
            uint lastInitializedTime,
            bytes5 parameters
        ) = PerpetualToken.getPerpetualTokenContext(perpTokenAddress);

        require(
            blockTime > lastInitializedTime.add(
                uint(uint8(parameters[PerpetualToken.RESIDUAL_PURCHASE_TIME_BUFFER])) * 3600
            ),
            "Insufficient block time"
        );


        int notional = BitmapAssetsHandler.getifCashNotional(perpTokenAddress, cashGroup.currencyId, maturity);
        if (notional < 0 && fCashAmountToPurchase < 0) {
            if (fCashAmountToPurchase < notional) fCashAmountToPurchase = notional;
        } else if (notional > 0 && fCashAmountToPurchase > 0) {
            if (fCashAmountToPurchase > notional) fCashAmountToPurchase = notional;
        } else {
            revert("Invalid amount");
        }

        int netAssetCashPerpToken = getResidualPrice(
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
        uint maturity,
        uint blockTime,
        int fCashAmount,
        bytes5 parameters
    ) internal view returns (int) {
        uint oracleRate = cashGroup.getOracleRate(markets, maturity, blockTime);
        uint purchaseIncentive = uint(uint8(parameters[PerpetualToken.RESIDUAL_PURCHASE_INCENTIVE])) * 10 * Market.BASIS_POINT;

        if (fCashAmount > 0) {
            oracleRate = oracleRate.add(purchaseIncentive);
        } else if (oracleRate > purchaseIncentive) {
            oracleRate = oracleRate.sub(purchaseIncentive);
        } else {
            // If the oracle rate is less than the purchase incentive floor the interest rate at zero
            oracleRate = 0;
        }

        int exchangeRate = Market.getExchangeRateFromImpliedRate(oracleRate, maturity.sub(blockTime));
        return cashGroup.assetRate.convertInternalFromUnderlying(fCashAmount.mul(Market.RATE_PRECISION).div(exchangeRate));
    }

    function updatePerpTokenPortfolio(
        address perpTokenAddress,
        CashGroupParameters memory cashGroup,
        uint maturity,
        uint lastInitializedTime,
        int fCashAmountToPurchase,
        int netAssetCashPerpToken
    ) private {
        bytes32 ifCashBitmap = BitmapAssetsHandler.getAssetsBitmap(perpTokenAddress, cashGroup.currencyId);
        ifCashBitmap = BitmapAssetsHandler.setifCashAsset(
            perpTokenAddress,
            cashGroup.currencyId,
            maturity,
            lastInitializedTime,
            fCashAmountToPurchase.neg(),
            ifCashBitmap
        );
        BitmapAssetsHandler.setAssetsBitmap(perpTokenAddress, cashGroup.currencyId, ifCashBitmap);

        (
            int perpTokenCashBalance,
            /* perpToken.balanceState.storedPerpetualTokenBalance */,
            /* lastIncentiveMint */
        ) = BalanceHandler.getBalanceStorage(perpTokenAddress, cashGroup.currencyId);
        perpTokenCashBalance = perpTokenCashBalance.add(netAssetCashPerpToken);
        // This will ensure that the cash balance is not negative
        BalanceHandler.setBalanceStorageForPerpToken(perpTokenAddress, cashGroup.currencyId, perpTokenCashBalance);
    }

    function placefCashAssetInCounterparty(
        address counterparty,
        AccountStorage memory counterpartyContext,
        uint currencyId,
        uint maturity,
        int fCashAmount
    ) internal {
        if (counterpartyContext.bitmapCurrencyId != 0) {
            require(counterpartyContext.bitmapCurrencyId == currencyId, "Invalid cash pair");
            bytes32 ifCashBitmap = BitmapAssetsHandler.getAssetsBitmap(counterparty, currencyId);
            ifCashBitmap = BitmapAssetsHandler.setifCashAsset(
                counterparty,
                currencyId,
                maturity,
                counterpartyContext.nextSettleTime,
                fCashAmount,
                ifCashBitmap
            );
            BitmapAssetsHandler.setAssetsBitmap(counterparty, currencyId, ifCashBitmap);
        } else {
            PortfolioState memory portfolioState = PortfolioHandler.buildPortfolioState(
                counterparty,
                counterpartyContext.assetArrayLength,
                1
            );
            portfolioState.addAsset(currencyId, maturity, AssetHandler.FCASH_ASSET_TYPE, fCashAmount, false);
            counterpartyContext.storeAssetsAndUpdateContext(counterparty, portfolioState);
        }
    }

    function _mintCashPair(
        address account,
        CashGroupParameters memory cashGroup,
        uint blockTime,
        bytes32 trade
    ) internal returns (uint, int) {
        address counterparty = address(bytes20(trade << 8));
        uint maturity = uint(uint32(bytes4(trade << 168)));
        // limit of 360 million
        int fCashAmountForCounterparty = int(int56(bytes7(trade << 200)));

        if (fCashAmountForCounterparty < 0) {
            // TODO: Requires authorization to deposit borrow
            require(account != address(0));
        }

        require(maturity > blockTime, "Invalid maturity");
        AccountStorage memory counterpartyContext = AccountContextHandler.getAccountContext(counterparty);
        placefCashAssetInCounterparty(
            counterparty,
            counterpartyContext,
            cashGroup.currencyId,
            maturity,
            fCashAmountForCounterparty
        );

        if (counterpartyContext.hasDebt != 0x00) {
            // Do free collateral check on counterparty
            FreeCollateralExternal.checkFreeCollateralAndRevert(counterparty);
        }
        counterpartyContext.setAccountContext(counterparty);

        return (maturity, fCashAmountForCounterparty.neg());
    }

}