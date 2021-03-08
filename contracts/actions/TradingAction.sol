// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./MintPerpetualTokenAction.sol";
import "./RedeemPerpetualTokenAction.sol";
import "../math/SafeInt256.sol";
import "../common/Market.sol";
import "../common/CashGroup.sol";
import "../storage/BalanceHandler.sol";
import "../storage/SettleAssets.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/StorageLayoutV1.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

// enum OperationType {
//     ContractCall,       // (address contract, bytes calldata)
// }

enum DepositType {
    DepositAsset,
    DepositAssetUseCashBalance,
    DepositUnderlying,
    MintPerpetual,
    RedeemPerpetual
}

struct Deposit {
    DepositType depositType;
    uint16 currencyId;
    // TODO: this must be marked as internal precision for mint perpetual tokens
    uint88 amountExternalPrecision;
}

enum AMMTradeType {
    Borrow,
    Lend,
    AddLiquidity,
    RemoveLiquidity
}

struct AMMTrade {
    AMMTradeType tradeType;
    uint16 currencyId;
    uint8 marketIndex;
    uint88 amount;
    uint32 minImpliedRate;
    uint32 maxImpliedRate;
}

struct Withdraw {
    uint16 currencyId;
    uint88 amountInternalPrecision;
    bool redeemToUnderlying;
}


contract TradingAction is StorageLayoutV1, ReentrancyGuard {
    using BalanceHandler for BalanceState;
    using PortfolioHandler for PortfolioState;
    using Market for MarketParameters;
    using CashGroup for CashGroupParameters;
    using SafeInt256 for int;
    using SafeMath for uint;

    // TODO: add shortcut deposit functions for topping up collateral
    // function deposit() external payable {}
    // function depositUnderlying() external payable {}

    function batchOperation(
        address account,
        uint16[] calldata currencyIds,
        Deposit[] calldata deposits,
        AMMTrade[] calldata trades,
        Withdraw[] calldata withdraws
    ) external payable {
        // TODO: authorize action

        uint32 blockTime = uint32(block.timestamp);
        (
            AccountStorage memory accountContext,
            PortfolioState memory portfolioState,
            BalanceState[] memory balanceStates
        ) = initializeActionStateful(account, currencyIds, blockTime, trades.length > 0);

        if (deposits.length > 0) executeDeposits(account, deposits, balanceStates);
        if (trades.length > 0) executeTrades(account, trades, portfolioState, balanceStates, blockTime);
        // This will finalize balances internally and execute withdraws (if any) 
        finalizeBalances(account, withdraws, balanceStates, accountContext);

        // At this point all balances, market states and portfolio states should be finalized. Just need to check free
        // collateral if required.
        // TODO: call free collateral
    }

    function initializeActionStateful(
        address account,
        uint16[] calldata currencyIds,
        uint blockTime,
        bool loadPortfolio
    ) internal view returns (
        AccountStorage memory,
        PortfolioState memory,
        BalanceState[] memory
    ) {
        AccountStorage memory accountContext = accountContextMapping[account];
        PortfolioState memory portfolioState;
        bool mustSettle = (accountContext.nextMaturingAsset != 0 && accountContext.nextMaturingAsset <= blockTime);
        BalanceState[] memory balanceStates = BalanceHandler.buildBalanceStateArray(account, currencyIds, accountContext);

        if (mustSettle || loadPortfolio) {
            // We only fetch the portfolio state if there will be trades added or if the account must be settled.
            portfolioState = PortfolioHandler.buildPortfolioState(account, 0);
        }

        if (mustSettle) {
            // 2k bytes over (26302)
            // remove settle liquidity tokens (25075.0)
            // remove get oracle rate (24809.0)
            // SettleAssets.getSettleAssetContextStateful(
            //     account,
            //     portfolioState,
            //     accountContext,
            //     balanceStates,
            //     blockTime
            // );
        }

        return (accountContext, portfolioState, balanceStates);
    }

    function executeDeposits(
        address account,
        Deposit[] calldata deposits,
        BalanceState[] memory balanceStates
    ) internal {
        uint balanceStateIndex;
        for (uint i; i < deposits.length; i++) {
            require(
                i > 0 && deposits[i].currencyId >= deposits[i - 1].currencyId,
                "Unsorted deposits"
            );
            while (balanceStates[balanceStateIndex].currencyId < deposits[i].currencyId) {
                balanceStateIndex += 1;
            }
            require(balanceStates[balanceStateIndex].currencyId == deposits[i].currencyId, "Currency not loaded");

            if (deposits[i].depositType == DepositType.DepositAsset
                || deposits[i].depositType == DepositType.DepositAssetUseCashBalance) {
                balanceStates[balanceStateIndex].depositAssetToken(
                    account,
                    deposits[i].amountExternalPrecision,
                    deposits[i].depositType == DepositType.DepositAssetUseCashBalance
                );
            } else if (deposits[i].depositType == DepositType.DepositUnderlying) {
                balanceStates[balanceStateIndex].depositUnderlyingToken(
                    account,
                    deposits[i].amountExternalPrecision
                );
            } else if (deposits[i].depositType == DepositType.MintPerpetual) {
                checkSufficientCash(balanceStates[balanceStateIndex], deposits[i].amountExternalPrecision);

                balanceStates[balanceStateIndex].netCashChange = balanceStates[balanceStateIndex].netCashChange
                    .sub(deposits[i].amountExternalPrecision);

                // Converts a given amount of cash (denominated in internal precision) into perpetual tokens
                int tokensMinted = MintPerpetualTokenAction(address(this)).perpetualTokenMintViaBatch(
                    deposits[i].currencyId,
                    deposits[i].amountExternalPrecision
                );

                balanceStates[balanceStateIndex].netPerpetualTokenTransfer = balanceStates[balanceStateIndex]
                    .netPerpetualTokenTransfer.add(tokensMinted);
            } else if (deposits[i].depositType == DepositType.RedeemPerpetual) {
                require(
                    balanceStates[balanceStateIndex].storedPerpetualTokenBalance
                        .add(balanceStates[balanceStateIndex].netPerpetualTokenTransfer) >= deposits[i].amountExternalPrecision,
                    "Insufficient tokens to redeem"
                );

                balanceStates[balanceStateIndex].netPerpetualTokenTransfer = balanceStates[balanceStateIndex]
                    .netPerpetualTokenTransfer.sub(deposits[i].amountExternalPrecision);

                int assetCash = RedeemPerpetualTokenAction(address(this)).perpetualTokenRedeemViaBatch(
                    deposits[i].currencyId,
                    deposits[i].amountExternalPrecision
                );

                balanceStates[balanceStateIndex].netCashChange = balanceStates[balanceStateIndex]
                    .netCashChange.add(assetCash);
            }
        }
    }

    function executeTrades(
        address account,
        AMMTrade[] calldata trades,
        PortfolioState memory portfolioState,
        BalanceState[] memory balanceStates,
        uint blockTime
    ) internal {
        uint balanceStateIndex;
        (
            CashGroupParameters memory cashGroup,
            MarketParameters[] memory markets
        ) = CashGroup.buildCashGroup(trades[0].currencyId);

        for (uint i; i < trades.length; i++) {
            require(
                i > 0 && trades[i].currencyId >= trades[i - 1].currencyId,
                "Unsorted trades"
            );

            while (balanceStates[balanceStateIndex].currencyId < trades[i].currencyId) {
                balanceStateIndex += 1;
            }
            require(balanceStates[balanceStateIndex].currencyId == trades[i].currencyId, "Currency not loaded");

            if (i > 0 && trades[i].currencyId != trades[i - 1].currencyId) {
                finalizeMarkets(markets);
                (cashGroup, markets) = CashGroup.buildCashGroup(trades[i].currencyId);
            }

            // bool needsLiquidity = (
            //     trades[i].tradeType == AMMTradeType.AddLiquidity || trades[i].tradeType == AMMTradeType.RemoveLiquidity
            // );
            MarketParameters memory market = cashGroup.getMarket(markets, trades[i].marketIndex, blockTime, false);

            int fCashAmount;
            {
                int netCashChange;
                // if (needsLiquidity) {
                    // (netCashChange, fCashAmount) = executeLiquidityTrade(portfolioState, trades[i], market);
                // } else if (trades[i].tradeType == AMMTradeType.Borrow) {
                if (trades[i].tradeType == AMMTradeType.Borrow) {
                    fCashAmount = int(trades[i].amount).neg();
                } else if (trades[i].tradeType == AMMTradeType.Lend) {
                    fCashAmount = int(trades[i].amount);
                }

                netCashChange = market.calculateTrade(cashGroup, fCashAmount, market.maturity.sub(blockTime));
                require(netCashChange != 0 && market.lastImpliedRate > trades[i].minImpliedRate, "Trade failed, slippage");
                if (trades[i].maxImpliedRate > 0) require(market.lastImpliedRate < trades[i].maxImpliedRate, "Trade failed");

                // if (trades[i].tradeType == AMMTradeType.AddLiquidity || trades[i].tradeType == AMMTradeType.Lend) {
                if (trades[i].tradeType == AMMTradeType.Lend) {
                    checkSufficientCash(balanceStates[balanceStateIndex], netCashChange);
                }
                balanceStates[balanceStateIndex].netCashChange = balanceStates[balanceStateIndex].netCashChange.add(netCashChange);
            }

            portfolioState.addAsset(trades[i].currencyId, market.maturity, AssetHandler.FCASH_ASSET_TYPE,
                fCashAmount, false);
        }

        // Finalize the last set of markets not caught by a cash group change
        finalizeMarkets(markets);
        portfolioState.storeAssets(assetArrayMapping[account]);
    }

    function executeLiquidityTrade(
        PortfolioState memory portfolioState,
        AMMTrade calldata trade,
        MarketParameters memory market
    ) private pure returns (int, int) {
        int netCashChange;
        int fCashAmount;

        if (trade.tradeType == AMMTradeType.AddLiquidity) {
            netCashChange = int(trade.amount);
            int liquidityTokens;
            (liquidityTokens, fCashAmount) = market.addLiquidity(netCashChange);

            // Add liquidity token asset
            portfolioState.addAsset(
                trade.currencyId,
                market.maturity,
                (1 + trade.marketIndex),
                liquidityTokens,
                false
            );
        } else {
            (netCashChange, fCashAmount) = market.removeLiquidity(trade.amount);
            // Remove liquidity token asset
            portfolioState.addAsset(
                trade.currencyId,
                market.maturity,
                (1 + trade.marketIndex),
                int(trade.amount).neg(),
                false
            );
        }

        return (netCashChange, fCashAmount);
    }

    function finalizeBalances(
        address account,
        Withdraw[] calldata withdraws,
        BalanceState[] memory balanceStates,
        AccountStorage memory accountContext
    ) internal {
        uint withdrawIndex;

        for (uint i; i < balanceStates.length; i++) {
            require(
                withdrawIndex > 0 && withdraws[withdrawIndex].currencyId >= withdraws[withdrawIndex - 1].currencyId,
                "Unsorted withdraws"
            );

            bool redeemToUnderlying;
            if (withdraws[withdrawIndex].currencyId == balanceStates[i].currencyId) {
                int withdrawAmount = withdraws[i].amountInternalPrecision;
                if (withdrawAmount == 0) {
                    // If the withdraw amount is set to zero, this signifies that the user wants to ensure that
                    // there is no residual cash balance (if possible) left in their portfolio
                    withdrawAmount = balanceStates[i].storedCashBalance
                        .add(balanceStates[i].netCashChange)
                        .add(balanceStates[i].netAssetTransferInternalPrecision);

                    // If the account will be left with a negative cash balance then cannot withdraw
                    if (withdrawAmount < 0) withdrawAmount = 0;
                }

                balanceStates[i].netAssetTransferInternalPrecision = balanceStates[i].netAssetTransferInternalPrecision
                    .sub(withdrawAmount);
                redeemToUnderlying = withdraws[i].redeemToUnderlying;

                withdrawIndex += 1;
            }

            // This line is 2250 bytes if we include it, remove SafeERC20 it is pretty bloated
            balanceStates[i].finalize(account, accountContext, redeemToUnderlying);
        }
    }

    function finalizeMarkets(MarketParameters[] memory markets) internal {
        // Finalize market states for previous trades
        for (uint j; j < markets.length; j++) {
            // TODO: switch this to settlement date
            markets[j].setMarketStorage(1);
        }
    }

    /**
     * @notice When lending, adding liquidity or minting perpetual tokens the account
     * must have a sufficient cash balance to do so otherwise they would go into a negative
     * cash balance.
     */
    function checkSufficientCash(
        BalanceState memory balanceState,
        int amountInternalPrecision
    ) internal pure {
        require(
            amountInternalPrecision >= 0 &&
            balanceState.storedCashBalance
                .add(balanceState.netCashChange)
                .add(balanceState.netAssetTransferInternalPrecision) >= amountInternalPrecision,
            "Insufficient cash"
        );
    }

}