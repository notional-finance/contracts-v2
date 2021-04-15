// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../external/SettleAssetsExternal.sol";
import "../external/FreeCollateralExternal.sol";
import "../external/actions/nTokenMintAction.sol";
import "../external/actions/nTokenRedeemAction.sol";
import "./TradingAction.sol";
import "../math/SafeInt256.sol";
import "../internal/balances/BalanceHandler.sol";
import "../internal/portfolio/PortfolioHandler.sol";
import "../internal/AccountContextHandler.sol";

contract DepositWithdrawAction {
    using BalanceHandler for BalanceState;
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountContext;
    using SafeInt256 for int256;

    event CashBalanceChange(address indexed account, uint16 currencyId, int256 netCashChange);
    event nTokenSupplyChange(address indexed account, uint16 currencyId, int256 tokenSupplyChange);
    event AccountSettled(address indexed account);

    /// @notice Method for manually settling an account, generally should not be called because other
    /// methods will check if an account needs to be settled automatically.
    /// @param account the account to settle
    /// @dev emit:AccountSettled
    /// @dev auth:none
    function settleAccount(address account) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        if (accountContext.mustSettleAssets()) {
            accountContext = SettleAssetsExternal.settleAssetsAndFinalize(account);
            accountContext.setAccountContext(account);
            emit AccountSettled(account);
        }
    }

    /// @notice Deposits and wraps the underlying token for a particular cToken. Does not settle assets or check free
    /// collateral, idea is to be as gas efficient as possible during potential liquidation events.
    /// @param account the account to deposit into
    /// @param currencyId currency id of the asset token that wraps this underlying
    /// @param amountExternalPrecision the amount of underlying tokens in its native decimal precision
    /// (i.e. 18 decimals for DAI or 6 decimals for USDC). This will be converted to 8 decimals during transfer.
    /// @return asset tokens minted and deposited to the account in internal decimals (8)
    /// @dev emit:CashBalanceChange
    /// @dev auth:none
    function depositUnderlyingToken(
        address account,
        uint16 currencyId,
        uint256 amountExternalPrecision
    ) external payable returns (uint256) {
        // No other authorization required on depositing
        require(msg.sender != address(this)); // dev: no internal call to deposit underlying

        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState memory balanceState;
        balanceState.loadBalanceState(account, currencyId, accountContext);

        // Int conversion overflow check done inside this method call
        // NOTE: using msg.sender here allows for a different sender to deposit tokens into the specified account. This may
        // be useful for on-demand collateral top ups from a third party
        int256 assetTokensReceivedInternal =
            balanceState.depositUnderlyingToken(msg.sender, int256(amountExternalPrecision));

        balanceState.finalize(account, accountContext, false);
        accountContext.setAccountContext(account);

        require(assetTokensReceivedInternal > 0); // dev: asset tokens negative
        emit CashBalanceChange(account, currencyId, assetTokensReceivedInternal);

        // NOTE: no free collateral checks required for depositing
        return uint256(assetTokensReceivedInternal);
    }

    /// @notice Deposits asset tokens into an account. Does not settle or check free collateral, idea is to
    /// make deposit as gas efficient as possible during potentital liquidation events.
    /// @param account the account to deposit into
    /// @param currencyId currency id of the asset token
    /// @param amountExternalPrecision the amount of asset tokens in its native decimal precision
    /// (i.e. 8 decimals for cTokens). This will be converted to 8 decimals during transfer if necessary.
    /// @return asset tokens minted and deposited to the account in internal decimals (8)
    /// @dev emit:CashBalanceChange
    /// @dev auth:none
    function depositAssetToken(
        address account,
        uint16 currencyId,
        uint256 amountExternalPrecision
    ) external returns (uint256) {
        require(msg.sender != address(this)); // dev: no internal call to deposit asset

        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState memory balanceState;
        balanceState.loadBalanceState(account, currencyId, accountContext);

        // prettier-ignore
        // Int conversion overflow check done inside this method call, useCashBalance is set to false. msg.sender
        // is used as the account in deposit to allow for other accounts to deposit on behalf of the given account.
        (
            int256 assetTokensReceivedInternal,
            /* assetAmountTransferred */
        ) = balanceState.depositAssetToken(
            msg.sender,
            int256(amountExternalPrecision),
            true // force transfer to ensure that msg.sender does the transfer, not account
        );

        balanceState.finalize(account, accountContext, false);
        accountContext.setAccountContext(account);

        require(assetTokensReceivedInternal > 0); // dev: asset tokens negative
        emit CashBalanceChange(account, currencyId, assetTokensReceivedInternal);

        // NOTE: no free collateral checks required for depositing
        return uint256(assetTokensReceivedInternal);
    }

    /// @notice Withdraws balances from Notional, may also redeem to underlying tokens on user request. Will settle
    /// and do free collateral checks if required. Can only be called by msg.sender, operators who want to withdraw for
    /// an account must do an authenticated call via ERC1155Action `safeTransferFrom` or `safeBatchTransferFrom`
    /// @param currencyId currency id of the asset token
    /// @param amountInternalPrecision the amount of asset tokens in its native decimal precision
    /// (i.e. 8 decimals for cTokens). This will be converted to 8 decimals during transfer if necessary.
    /// @dev emit:CashBalanceChange
    /// @dev auth:msg.sender
    /// @return the amount of tokens recieved by the account denominated in the destination token precision (if
    // redeeming to underlying the amount will be the underlying amount received in that token's native precision)
    function withdraw(
        uint16 currencyId,
        uint88 amountInternalPrecision,
        bool redeemToUnderlying
    ) external returns (uint256) {
        address account = msg.sender;

        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        // This happens before reading the balance state to get the most up to date cash balance
        _settleAccountIfRequiredAndFinalize(account, accountContext);

        BalanceState memory balanceState;
        balanceState.loadBalanceState(account, currencyId, accountContext);
        require(balanceState.storedCashBalance >= amountInternalPrecision, "Insufficient balance");
        balanceState.netAssetTransferInternalPrecision = int256(amountInternalPrecision).neg();

        int256 amountWithdrawn = balanceState.finalize(account, accountContext, redeemToUnderlying);
        // This will trigger a free collateral check if required
        _finalizeAccountContext(account, accountContext);

        require(amountWithdrawn <= 0);
        // Event emitted is denominated internal cash balances
        emit CashBalanceChange(account, currencyId, int256(amountInternalPrecision).neg());

        return uint256(amountWithdrawn.neg());
    }

    /// @notice Executes a batch of balance transfers including minting and redeeming nTokens.
    /// @param account the account for the action
    /// @param actions array of balance actions to take, must be sorted by currency id
    /// @dev emit:CashBalanceChange for each balance
    /// @dev auth:msg.sender auth:ERC1155
    function batchBalanceAction(address account, BalanceAction[] calldata actions)
        external
        payable
    {
        require(account == msg.sender || msg.sender == address(this), "Unauthorized");

        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        // Return any settle amounts here to reduce the number of storage writes to balances
        SettleAmount[] memory settleAmounts =
            _settleAccountIfRequiredAndStorePortfolio(account, accountContext);

        uint256 settleAmountIndex;
        BalanceState memory balanceState;
        for (uint256 i; i < actions.length; i++) {
            if (i > 0) {
                require(actions[i].currencyId > actions[i - 1].currencyId, "Unsorted actions");
            }

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

    /// @notice Executes a batch of balance transfers and trading actions
    /// @param account the account for the action
    /// @param actions array of balance actions with trades to take, must be sorted by currency id
    /// @dev emit:CashBalanceChange for each balance, emit:BatchTradeExecution for each trade set, emit:nTokenSupplyChange
    /// @dev auth:msg.sender auth:ERC1155
    function batchBalanceAndTradeAction(address account, BalanceActionWithTrades[] calldata actions)
        external
        payable
    {
        require(account == msg.sender || msg.sender == address(this), "Unauthorized");

        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        (SettleAmount[] memory settleAmounts, PortfolioState memory portfolioState) =
            _settleAccountIfRequiredAndReturnPortfolio(account, accountContext);

        uint256 settleAmountIndex;
        BalanceState memory balanceState;
        for (uint256 i; i < actions.length; i++) {
            if (i > 0) {
                require(actions[i].currencyId > actions[i - 1].currencyId, "Unsorted actions");
            }
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
                int256 netCash;
                if (accountContext.bitmapCurrencyId != 0) {
                    require(
                        accountContext.bitmapCurrencyId == actions[i].currencyId,
                        "Invalid trades for account"
                    );
                    bool didIncurDebt;
                    (netCash, didIncurDebt) = TradingAction.executeTradesBitmapBatch(
                        account,
                        accountContext,
                        actions[i].trades
                    );
                    if (didIncurDebt) {
                        accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_ASSET_DEBT;
                    }
                } else {
                    // NOTE: we return portfolio state here instead of setting it inside execueTradesArrayBatch
                    // because we want to only write to storage once after all trades are completed
                    (portfolioState, netCash) = TradingAction.executeTradesArrayBatch(
                        account,
                        actions[i].currencyId,
                        portfolioState,
                        actions[i].trades
                    );
                }

                // If the account owes cash after trading, ensure that it has enough
                if (netCash < 0) _checkSufficientCash(balanceState, netCash.neg());
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

        if (accountContext.bitmapCurrencyId == 0) {
            accountContext.storeAssetsAndUpdateContext(account, portfolioState, false);
        }

        // Finalize remaining settle amounts
        BalanceHandler.finalizeSettleAmounts(account, accountContext, settleAmounts);
        _finalizeAccountContext(account, accountContext);
    }

    /// @dev Loads balances, nets off settle amounts and then executes deposit actions
    function _preTradeActions(
        address account,
        uint256 settleAmountIndex,
        uint256 currencyId,
        SettleAmount[] memory settleAmounts,
        BalanceState memory balanceState,
        AccountContext memory accountContext,
        DepositActionType depositType,
        uint256 depositActionAmount
    ) private returns (uint256) {
        while (
            settleAmountIndex < settleAmounts.length &&
            settleAmounts[settleAmountIndex].currencyId < currencyId
        ) {
            // Loop through settleAmounts to find a matching currency
            settleAmountIndex += 1;
        }

        // This saves a number of memory allocations
        balanceState.loadBalanceState(account, currencyId, accountContext);

        if (settleAmountIndex < settleAmounts.length) {
            balanceState.netCashChange = settleAmounts[settleAmountIndex].netCashChange;
            // Set to zero so that we don't double count later
            settleAmounts[settleAmountIndex].netCashChange = 0;
        }

        _executeDepositAction(account, balanceState, depositType, depositActionAmount);

        return settleAmountIndex;
    }

    /// @dev Executes deposits
    function _executeDepositAction(
        address account,
        BalanceState memory balanceState,
        DepositActionType depositType,
        uint256 depositActionAmount_
    ) private {
        int256 depositActionAmount = int256(depositActionAmount_);
        int256 assetInternalAmount;
        require(depositActionAmount >= 0);

        if (depositType == DepositActionType.None) {
            return;
        } else if (
            depositType == DepositActionType.DepositAsset ||
            depositType == DepositActionType.DepositAssetAndMintNToken
        ) {
            // prettier-ignore
            (assetInternalAmount, /* */) = balanceState.depositAssetToken(
                account,
                depositActionAmount,
                false // no force transfer
            );
        } else if (
            depositType == DepositActionType.DepositUnderlying ||
            depositType == DepositActionType.DepositUnderlyingAndMintNToken
        ) {
            assetInternalAmount = balanceState.depositUnderlyingToken(account, depositActionAmount);
        }

        _executeNTokenAction(
            account,
            balanceState,
            depositType,
            depositActionAmount,
            assetInternalAmount
        );
    }

    /// @dev Executes nToken actions
    function _executeNTokenAction(
        address account,
        BalanceState memory balanceState,
        DepositActionType depositType,
        int256 depositActionAmount,
        int256 assetInternalAmount
    ) private {
        // After deposits have been actioned, check if we are minting nTokens
        if (
            depositType == DepositActionType.DepositAssetAndMintNToken ||
            depositType == DepositActionType.DepositUnderlyingAndMintNToken
        ) {
            _checkSufficientCash(balanceState, assetInternalAmount);
            balanceState.netCashChange = balanceState.netCashChange.sub(assetInternalAmount);

            // Converts a given amount of cash (denominated in internal precision) into perpetual tokens
            int256 tokensMinted =
                nTokenMintAction.nTokenMint(balanceState.currencyId, assetInternalAmount);

            balanceState.netPerpetualTokenSupplyChange = balanceState
                .netPerpetualTokenSupplyChange
                .add(tokensMinted);
        } else if (depositType == DepositActionType.RedeemNToken) {
            require(
                balanceState
                    .storedPerpetualTokenBalance
                    .add(balanceState.netPerpetualTokenTransfer) // transfers would not occur at this point
                    .add(balanceState.netPerpetualTokenSupplyChange) >= depositActionAmount,
                "Insufficient token balance"
            );

            balanceState.netPerpetualTokenSupplyChange = balanceState
                .netPerpetualTokenSupplyChange
                .sub(depositActionAmount);

            int256 assetCash =
                nTokenRedeemAction(address(this)).nTokenRedeemViaBatch(
                    balanceState.currencyId,
                    depositActionAmount
                );

            balanceState.netCashChange = balanceState.netCashChange.add(assetCash);
        }

        if (balanceState.netPerpetualTokenSupplyChange != 0) {
            emit nTokenSupplyChange(
                account,
                uint16(balanceState.currencyId),
                balanceState.netPerpetualTokenSupplyChange
            );
        }
    }

    /// @dev Calculations any withdraws and finalizes balances
    function _calculateWithdrawActionAndFinalize(
        address account,
        AccountContext memory accountContext,
        BalanceState memory balanceState,
        uint256 withdrawAmountInternalPrecision,
        bool withdrawEntireCashBalance,
        bool redeemToUnderlying
    ) private {
        int256 withdrawAmount = int256(withdrawAmountInternalPrecision);
        require(withdrawAmount >= 0); // dev: withdraw action overflow

        if (withdrawEntireCashBalance) {
            // This option is here so that accounts do not end up with dust after lending since we generally
            // cannot calculate exact cash amounts from the liquidity curve.
            withdrawAmount = balanceState.storedCashBalance.add(balanceState.netCashChange).add(
                balanceState.netAssetTransferInternalPrecision
            );

            // If the account has a negative cash balance then cannot withdraw
            if (withdrawAmount < 0) withdrawAmount = 0;
        }

        balanceState.netAssetTransferInternalPrecision = balanceState
            .netAssetTransferInternalPrecision
            .sub(withdrawAmount);

        balanceState.finalize(account, accountContext, redeemToUnderlying);
        int256 finalBalanceChange =
            balanceState.netCashChange.add(balanceState.netAssetTransferInternalPrecision);

        if (finalBalanceChange != 0) {
            emit CashBalanceChange(account, uint16(balanceState.currencyId), finalBalanceChange);
        }
    }

    function _finalizeAccountContext(address account, AccountContext memory accountContext)
        private
    {
        // At this point all balances, market states and portfolio states should be finalized. Just need to check free
        // collateral if required.
        accountContext.setAccountContext(account);
        if (accountContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(account);
        }
    }

    /// @notice When lending, adding liquidity or minting nTokens the account must have a sufficient cash balance
    /// to do so.
    function _checkSufficientCash(BalanceState memory balanceState, int256 amountInternalPrecision)
        private
        pure
    {
        require(
            amountInternalPrecision >= 0 &&
                balanceState.storedCashBalance.add(balanceState.netCashChange).add(
                    balanceState.netAssetTransferInternalPrecision
                ) >=
                amountInternalPrecision,
            "Insufficient cash"
        );
    }

    function _settleAccountIfRequiredAndReturnPortfolio(
        address account,
        AccountContext memory accountContext
    ) private returns (SettleAmount[] memory, PortfolioState memory) {
        if (accountContext.mustSettleAssets()) {
            (
                AccountContext memory newAccountContext,
                SettleAmount[] memory settleAmounts,
                PortfolioState memory portfolioState
            ) = SettleAssetsExternal.settleAssetsAndReturnAll(account);

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
        AccountContext memory accountContext
    ) private returns (SettleAmount[] memory) {
        SettleAmount[] memory settleAmounts;

        if (accountContext.mustSettleAssets()) {
            (accountContext, settleAmounts) = SettleAssetsExternal.settleAssetsAndStorePortfolio(
                account
            );
        }

        return settleAmounts;
    }

    function _settleAccountIfRequiredAndFinalize(
        address account,
        AccountContext memory accountContext
    ) private {
        if (accountContext.mustSettleAssets()) {
            accountContext = SettleAssetsExternal.settleAssetsAndFinalize(account);
        }
    }
}
