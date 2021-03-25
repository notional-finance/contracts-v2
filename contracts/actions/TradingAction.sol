// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./FreeCollateralExternal.sol";
import "./SettleAssetsExternal.sol";
import "./DepositWithdrawAction.sol";
import "../math/SafeInt256.sol";
import "../common/Market.sol";
import "../common/CashGroup.sol";
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
    // (uint8, int88)
    PurchasePerpetualTokenResidual,
    // (uint8, address, int88)
    SettleCashDebt
}

library TradingAction {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;
    using Market for MarketParameters;
    using CashGroup for CashGroupParameters;
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
        int[] memory values = new int[](3);

        for (uint i; i < trades.length; i++) {
            uint maturity;
            (
                maturity,
                values[1], // cash amount
                values[2] // fCashAmount
            ) = _executeTrade(account, cashGroup, markets, trades[i], blockTime);

            ifCashBitmap = BitmapAssetsHandler.setifCashAsset(
                account,
                currencyId,
                maturity,
                accountContext.nextSettleTime,
                values[2], // fCashAmount
                ifCashBitmap
            );
            // netCash = netCash + cashAmount
            values[0] = values[0].add(values[1]);
        }

        BitmapAssetsHandler.setAssetsBitmap(account, currencyId, ifCashBitmap);
        emit BatchTradeExecution(account, uint16(currencyId));

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
        int[] memory values = new int[](3);

        for (uint i; i < trades.length; i++) {
            TradeActionType tradeType = TradeActionType(uint(uint8(bytes1(trades[i]))));

            if (tradeType == TradeActionType.AddLiquidity || tradeType == TradeActionType.RemoveLiquidity) {
                // cashAmount
                values[1] = _executeLiquidityTrade(cashGroup, tradeType, trades[i], portfolioState, values[0]);
            } else {
                uint maturity;
                // (maturity, cashAmount, fCashAmount)
                (maturity, values[1], values[2]) = _executeTrade(account, cashGroup, markets, trades[i], blockTime);
                // Stack issues here :(
                _addfCashAsset(portfolioState, currencyId, maturity, values[2]);
            }

            // netCash = netCash + cashAmount
            values[0] = values[0].add(values[1]);
        }

        emit BatchTradeExecution(account, uint16(currencyId));

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
        MarketParameters[] memory markets,
        bytes32 trade,
        uint blockTime
    ) internal returns (uint, int, int) {
        TradeActionType tradeType = TradeActionType(uint(uint8(bytes1(trade))));

        uint maturity;
        int cashAmount;
        int fCashAmount;
        if (tradeType == TradeActionType.MintCashPair) {
            (maturity, fCashAmount) = _mintCashPair(account, cashGroup, blockTime, trade);
        } else if (tradeType == TradeActionType.PurchasePerpetualTokenResidual) {
            (maturity, cashAmount, fCashAmount) = _purchaseResidual(cashGroup, markets, blockTime, trade);
        } else if (tradeType == TradeActionType.SettleCashDebt) {
            // Settling debts will use the oracle rate from the 3 month market
            (maturity, cashAmount, fCashAmount) = _settleCashDebt(cashGroup, markets, blockTime, trade);
        } else if (tradeType == TradeActionType.Lend || tradeType == TradeActionType.Borrow) {
            (maturity, cashAmount, fCashAmount) = _executeLendBorrowTrade(
                cashGroup,
                markets,
                tradeType,
                blockTime,
                trade
            );
        } else {
            revert("Invalid trade type");
        }

        return (maturity, cashAmount, fCashAmount);
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
        {
            uint blockTime = block.timestamp;
            uint maturity = CashGroup.getReferenceTime(blockTime).add(CashGroup.getTradedMarket(marketIndex));
            market.loadMarket(
                cashGroup.currencyId,
                maturity,
                blockTime,
                true,
                cashGroup.getRateOracleTimeWindow()
            );
        }

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
        MarketParameters[] memory markets,
        TradeActionType tradeType,
        uint blockTime,
        bytes32 trade
    ) internal returns (uint, int, int) {
        uint marketIndex = uint(uint8(bytes1(trade << 8)));
        // TODO: refactor this to get rid of the markets array
        MarketParameters memory market = cashGroup.getMarket(
            markets,
            marketIndex,
            blockTime,
            false
        );

        int fCashAmount;
        if (tradeType == TradeActionType.Borrow) {
            fCashAmount = int(uint88(bytes11(trade << 16))).neg();
        } else {
            fCashAmount = int(uint88(bytes11(trade << 16)));
        }

        int cashAmount = market.calculateTrade(
            cashGroup,
            fCashAmount.neg(),
            market.maturity.sub(blockTime),
            marketIndex
        );

        uint rateLimit = uint(uint32(bytes4(trade << 104)));
        if (rateLimit != 0) {
            if (tradeType == TradeActionType.Borrow) {
                require(market.lastImpliedRate <= rateLimit, "Trade failed, slippage");
            } else {
                require(market.lastImpliedRate >= rateLimit, "Trade failed, slippage");
            }
        }
        market.setMarketStorage();

        return (market.maturity, cashAmount, fCashAmount);
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
        // DepositWithdrawAction._settleAccountIfRequiredAndFinalize(counterparty, counterpartyContext);

        // This will check if the amountToSettle is valid and revert if it is not. Amount to settle is a positive
        // number always.
        amountToSettle = BalanceHandler.setBalanceStorageForSettleCashDebt(
            counterparty,
            cashGroup.currencyId,
            amountToSettle
        );

        // Settled account must borrow from the 3 month market at a penalty rate. Even if the market is
        // not initialized we can still settle cash debts because we reference the previous 3 month market's oracle
        // rate which is where the new 3 month market's oracle rate will be initialized to.
        uint threeMonthMaturity = CashGroup.getReferenceTime(blockTime) + CashGroup.QUARTER;
        int fCashAmount = _getfCashSettleAmount(cashGroup, markets, threeMonthMaturity, blockTime, amountToSettle);

        // It's possible that this action will put an account into negative free collateral. In this case they
        // will immediately become eligible for liquidation and the account settling the debt can also liquidate
        // them in the same transaction. Do not run a free collateral check here to allow this to happen.
        _placefCashAssetInCounterparty(
            counterparty,
            counterpartyContext,
            cashGroup.currencyId,
            threeMonthMaturity,
            fCashAmount.neg() // This is the debt the settled account will incur
        );
        counterpartyContext.setAccountContext(counterparty);

        // NOTE: net cash change for the settler is negative, they must produce the cash, fCashAmount
        // here is positive, it is the amount that the settler will receive
        return (threeMonthMaturity, amountToSettle.neg(), fCashAmount);
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
        _placefCashAssetInCounterparty(
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

    function _purchaseResidual(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint blockTime,
        bytes32 trade
    ) internal returns (uint, int, int) {
        uint maturity = uint(uint32(bytes4(trade << 168)));
        // limit of 360 million
        int fCashAmountToPurchase = int(int88(bytes11(trade << 200)));

        require(maturity > blockTime, "Invalid maturity");
        // _placefCashAssetInCounterparty(
        //     counterparty,
        //     counterpartyContext,
        //     cashGroup.currencyId,
        //     maturity,
        //     fCashAmountToPurchase
        // );

        // int cashAmount = _getCashPrice(cashGroup, markets, maturity, blockTime, fCashAmountToPurchase);
        // // TODO: set counterparty context?

        // return (maturity, cashAmount, fCashAmountToPurchase.neg());
    }

    function _getCashPrice(
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        uint maturity,
        uint blockTime,
        int fCashAmount
    ) internal view returns (int) {
        // TODO: this needs to be set somewhere and check fCashAmountToPurchase
        uint priceDifference = 0;
        uint oracleRate = cashGroup.getOracleRate(markets, maturity, blockTime);
        int exchangeRate = Market.getExchangeRateFromImpliedRate(
            oracleRate.add(priceDifference),
            maturity.sub(blockTime)
        );

        return fCashAmount.mul(Market.RATE_PRECISION).div(exchangeRate);
    }

    function _placefCashAssetInCounterparty(
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
}