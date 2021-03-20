// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./FreeCollateralExternal.sol";
import "./SettleAssetsExternal.sol";
import "./MintPerpetualTokenAction.sol";
import "./RedeemPerpetualTokenAction.sol";
import "./TradingAction.sol";
import "../math/SafeInt256.sol";
import "../storage/SettleAssets.sol";
import "../storage/BalanceHandler.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/AccountContextHandler.sol";

enum DepositActionType {
    None,
    DepositAsset,
    DepositUnderlying,
    MintPerpetual,
    RedeemPerpetual
}

struct BalanceAction {
    DepositActionType actionType;
    uint16 currencyId;
    // TODO: maybe make this just bytes to save gas
    uint depositActionAmount;
    uint withdrawAmountInternalPrecision;
    bool withdrawEntireCashBalance;
    bool redeemToUnderlying;
}

struct BalanceActionWithTrades {
    DepositActionType actionType;
    uint16 currencyId;
    // TODO: maybe make this just bytes to save gas
    uint depositActionAmount;
    uint withdrawAmountInternalPrecision;
    bool withdrawEntireCashBalance;
    bool redeemToUnderlying;
    bytes32[] trades;
}

library DepositWithdrawAction {
    using BalanceHandler for BalanceState;
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;
    using SafeInt256 for int;

    /**
     * @notice Deposits and wraps the underlying token for a particular cToken. Notional should never have
     * any balances denominated in the underlying.
     */
    function depositUnderlyingToken(
        address account,
        uint16 currencyId,
        uint amountExternalPrecision
    ) external returns (uint) {
        // No other authorization required on depositing
        require(msg.sender != address(this)); // dev: no internal call to deposit underlying

        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState memory balanceState = BalanceHandler.buildBalanceState(account, currencyId, accountContext);
        // Int conversion overflow check done inside this method call
        int assetTokensReceivedInternal = balanceState.depositUnderlyingToken(account, int(amountExternalPrecision));

        balanceState.finalize(account, accountContext, false);
        accountContext.setAccountContext(account);

        require(assetTokensReceivedInternal > 0); // dev: asset tokens negative
        // NOTE: no free collateral checks required for depositing
        return uint(assetTokensReceivedInternal);
    }

    /**
     * @notice Deposits tokens that are already wrapped.
     */
    function depositAssetToken(
        address account,
        uint16 currencyId,
        uint amountExternalPrecision
    ) external returns (uint) {
        // No other authorization required on depositing
        require(msg.sender != address(this)); // dev: no internal call to deposit asset

        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState memory balanceState = BalanceHandler.buildBalanceState(account, currencyId, accountContext);
        // Int conversion overflow check done inside this method call, useCashBalance is set to false. It does
        // not make sense in this context.
        (
            int assetTokensReceivedInternal,
            /* assetAmountTransferred */
        ) = balanceState.depositAssetToken(account, int(amountExternalPrecision), false);

        balanceState.finalize(account, accountContext, false);
        accountContext.setAccountContext(account);

        require(assetTokensReceivedInternal > 0); // dev: asset tokens negative
        // NOTE: no free collateral checks required for depositing
        return uint(assetTokensReceivedInternal);
    }

    /**
     * @notice Withdraws balances from Notional, may also redeem to underlying tokens on user request. This method
     * requires authentication and will settle an account if required. If the account has debt, it will also trigger
     * a free collateral check.
     */
    function withdraw(
        address account,
        uint16 currencyId,
        uint88 amountInternalPrecision,
        bool redeemToUnderlying
    ) external returns (uint) {
        require(account == msg.sender || msg.sender == address(this), "Unauthorized");

        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        // This happens before reading the balance state to get the most up to date cash balance
        _settleAccountIfRequiredAndFinalize(account, accountContext);

        BalanceState memory balanceState = BalanceHandler.buildBalanceState(account, currencyId, accountContext);
        require(balanceState.storedCashBalance >= amountInternalPrecision, "Insufficient balance");
        balanceState.netAssetTransferInternalPrecision = int(amountInternalPrecision).neg();

        int amountWithdrawn = balanceState.finalize(account, accountContext, redeemToUnderlying);
        // This will trigger a free collateral check if required
        _finalizeAccountContext(account, accountContext);

        require(amountWithdrawn <= 0);
        return uint(amountWithdrawn.neg());
    }

    /**
     * @notice Executes a batch of balance transfers including minting and redeeming perpetual tokens.
     */
    function batchBalanceAction(
        address account,
        BalanceAction[] calldata actions
    ) external {
        require(account == msg.sender || msg.sender == address(this), "Unauthorized");

        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        // This happens before reading the balance state to get the most up to date cash balance
        SettleAmount[] memory settleAmounts = _settleAccountIfRequiredAndStorePortfolio(account, accountContext);

        uint settleAmountIndex;
        BalanceState memory balanceState;
        for (uint i; i < actions.length; i++) {
            if (i > 0) require(actions[i].currencyId >= actions[i - 1].currencyId, "Unsorted actions");

            settleAmountIndex = _preTradeActions(
                account,
                settleAmountIndex,
                actions[i].currencyId,
                settleAmounts,
                balanceState,
                accountContext,
                actions[i].actionType,
                actions[i].depositActionAmount
            );

            _calculateWithdrawActionAndFinalize(
                account,
                accountContext,
                balanceState,
                actions[i].withdrawAmountInternalPrecision,
                actions[i].withdrawEntireCashBalance,
                actions[i].redeemToUnderlying
            );
        }

        // Finalize remaining settle amounts
        BalanceHandler.finalizeSettleAmounts(account, accountContext, settleAmounts);
        _finalizeAccountContext(account, accountContext);
    }

    function batchBalanceAndTradeActions(
        address account,
        BalanceActionWithTrades[] calldata actions
    ) external {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        (
            SettleAmount[] memory settleAmounts,
            PortfolioState memory portfolioState
        ) = _settleAccountIfRequiredAndReturnPortfolio(account, accountContext);

        uint settleAmountIndex;
        BalanceState memory balanceState;
        for (uint i; i < actions.length; i++) {
            if (i > 0) require(actions[i].currencyId >= actions[i - 1].currencyId, "Unsorted actions");
            settleAmountIndex = _preTradeActions(
                account,
                settleAmountIndex,
                actions[i].currencyId,
                settleAmounts,
                balanceState,
                accountContext,
                actions[i].actionType,
                actions[i].depositActionAmount
            );

            if (actions[i].trades.length > 0) {
                int netCash;
                (portfolioState, netCash) = TradingAction.executeTradesArrayBatch(
                    account,
                    actions[i].currencyId,
                    portfolioState,
                    actions[i].trades
                );
                balanceState.netCashChange = balanceState.netCashChange.add(netCash);
            }

            _calculateWithdrawActionAndFinalize(
                account,
                accountContext,
                balanceState,
                actions[i].withdrawAmountInternalPrecision,
                actions[i].withdrawEntireCashBalance,
                actions[i].redeemToUnderlying
            );
        }

        portfolioState.storeAssets(account, accountContext);

        // Finalize remaining settle amounts
        BalanceHandler.finalizeSettleAmounts(account, accountContext, settleAmounts);
        _finalizeAccountContext(account, accountContext);
    }

    function _preTradeActions(
        address account,
        uint settleAmountIndex,
        uint currencyId,
        SettleAmount[] memory settleAmounts,
        BalanceState memory balanceState,
        AccountStorage memory accountContext,
        DepositActionType depositType, 
        uint depositActionAmount
    ) internal returns (uint) {
        while (settleAmountIndex < settleAmounts.length
            && settleAmounts[settleAmountIndex].currencyId < currencyId) {
            // Loop through settleAmounts to find a matching currency
            settleAmountIndex += 1;
        }

        // This saves a number of memory allocations
        balanceState.loadBalanceState(account, currencyId, accountContext);

        if (settleAmountIndex < settleAmounts.length) {
            balanceState.netCashChange = settleAmounts[settleAmountIndex].netCashChange;
            settleAmounts[settleAmountIndex].netCashChange = 0;
        }

        _executeDepositAction(account, balanceState, depositType, depositActionAmount);

        return settleAmountIndex;
    }

    function _settleAccountIfRequiredAndReturnPortfolio(
        address account,
        AccountStorage memory accountContext
    ) internal returns (SettleAmount[] memory, PortfolioState memory) {
        if (accountContext.nextMaturingAsset != 0 && accountContext.nextMaturingAsset <= block.timestamp) {
            (
                AccountStorage memory newAccountContext,
                SettleAmount[] memory settleAmounts,
                PortfolioState memory portfolioState
            ) = SettleAssetsExternal.settleAssetsAndReturnPortfolio(account);

            accountContext = newAccountContext;
            return (settleAmounts, portfolioState);
        }

        return (
            new SettleAmount[](0),
            PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0)
        );
    }

    function _settleAccountIfRequiredAndStorePortfolio(
        address account,
        AccountStorage memory accountContext
    ) internal returns (SettleAmount[] memory) {
        SettleAmount[] memory settleAmounts;

        if (accountContext.nextMaturingAsset != 0 && accountContext.nextMaturingAsset <= block.timestamp) {
            (
                accountContext,
                settleAmounts
            ) = SettleAssetsExternal.settleAssetsAndStorePortfolio(account);
        }

        return settleAmounts;
    }

    /**
     * @notice Settles assets and finalizes portfolio changes and balances
     */
    function _settleAccountIfRequiredAndFinalize(
        address account,
        AccountStorage memory accountContext
    ) internal {
        if (accountContext.nextMaturingAsset != 0 && accountContext.nextMaturingAsset <= block.timestamp) {
            accountContext = SettleAssetsExternal.settleAssetsAndFinalize(account);
        }
    }

    function _executeDepositAction(
        address account,
        BalanceState memory balanceState,
        DepositActionType depositType,
        uint depositActionAmount_
    ) internal {
        int depositActionAmount = int(depositActionAmount_);
        require(depositActionAmount >= 0);

        if (depositType == DepositActionType.None) {
            return;
        } else if (depositType == DepositActionType.DepositAsset) {
            balanceState.depositAssetToken(account, depositActionAmount, false);
        } else if (depositType == DepositActionType.DepositUnderlying) {
            balanceState.depositUnderlyingToken(account, depositActionAmount);
        } else if (depositType == DepositActionType.MintPerpetual) {
            _checkSufficientCash(balanceState, depositActionAmount);
            balanceState.netCashChange = balanceState.netCashChange.sub(depositActionAmount);

            // Converts a given amount of cash (denominated in internal precision) into perpetual tokens
            int tokensMinted = MintPerpetualTokenAction.perpetualTokenMintViaBatch(
                balanceState.currencyId,
                depositActionAmount
            );

            balanceState.netPerpetualTokenSupplyChange = balanceState.netPerpetualTokenSupplyChange
                .add(tokensMinted);
        } else if (depositType == DepositActionType.RedeemPerpetual) {
            require(
                balanceState.storedPerpetualTokenBalance
                    // It is not possible to have transfers here
                    .add(balanceState.netPerpetualTokenTransfer)
                    .add(balanceState.netPerpetualTokenSupplyChange)
                >= depositActionAmount,
                "Insufficient token balance"
            );

            balanceState.netPerpetualTokenSupplyChange = balanceState.netPerpetualTokenSupplyChange
                .sub(depositActionAmount);

            int assetCash = RedeemPerpetualTokenAction.perpetualTokenRedeemViaBatch(
                balanceState.currencyId,
                depositActionAmount
            );

            balanceState.netCashChange = balanceState.netCashChange.add(assetCash);
        }
    }

    function _calculateWithdrawActionAndFinalize(
        address account,
        AccountStorage memory accountContext,
        BalanceState memory balanceState,
        uint withdrawAmountInternalPrecision,
        bool withdrawEntireCashBalance,
        bool redeemToUnderlying
    ) internal {
        int withdrawAmount = int(withdrawAmountInternalPrecision);
        require(withdrawAmount > 0); // dev: withdraw action overflow

        if (withdrawEntireCashBalance) {
            withdrawAmount = balanceState.storedCashBalance
                .add(balanceState.netCashChange)
                .add(balanceState.netAssetTransferInternalPrecision);

            // If the account has a negative cash balance then cannot withdraw
            if (withdrawAmount < 0) withdrawAmount = 0;
        }

        balanceState.netAssetTransferInternalPrecision = balanceState.netAssetTransferInternalPrecision
            .sub(withdrawAmount);
        balanceState.finalize(account, accountContext, redeemToUnderlying);
    }

    function _finalizeAccountContext(
        address account,
        AccountStorage memory accountContext
    ) internal {
        // At this point all balances, market states and portfolio states should be finalized. Just need to check free
        // collateral if required.
        accountContext.setAccountContext(account);
        if (accountContext.hasDebt) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(account);
        }
    }

    /**
     * @notice When lending, adding liquidity or minting perpetual tokens the account
     * must have a sufficient cash balance to do so otherwise they would go into a negative
     * cash balance.
     */
    function _checkSufficientCash(
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