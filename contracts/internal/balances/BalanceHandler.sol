// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./Incentives.sol";
import "./TokenHandler.sol";
import "../AccountContextHandler.sol";
import "../../global/Types.sol";
import "../../global/Constants.sol";
import "../../math/SafeInt256.sol";

library BalanceHandler {
    using SafeInt256 for int256;
    using TokenHandler for Token;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountStorage;

    /// @notice Deposits asset tokens into an account
    /// @dev Handles two special cases when depositing tokens into an account.
    ///  - If a token has transfer fees then the amount specified does not equal the amount that the contract
    ///    will receive. Complete the deposit here rather than in finalize so that the contract has the correct
    ///    balance to work with.
    ///  - A method may specify that it wants to apply positive cash balances against the deposit, netting off the
    ///    amount that must actually be transferred. In this case we use the cash balance to determine the net amount
    ///    required to deposit
    /// @return Returns two values:
    ///  - assetAmountInternal which is the converted asset amount accounting for transfer fees
    ///  - assetAmountTransferred which is the internal precision amount transferred into the account
    function depositAssetToken(
        BalanceState memory balanceState,
        address account,
        int256 assetAmountExternal,
        bool useCashBalance
    ) internal returns (int256, int256) {
        if (assetAmountExternal == 0) return (0, 0);
        require(assetAmountExternal > 0); // dev: deposit asset token amount negative
        Token memory token = TokenHandler.getToken(balanceState.currencyId, false);
        int256 assetAmountInternal = token.convertToInternal(assetAmountExternal);
        int256 assetAmountTransferred;

        if (useCashBalance) {
            // Calculate what we assume the total cash position to be if transfers and cash changes are
            // successful. We then apply any positive amount of this total cash balance to net off the deposit.
            int256 totalCash =
                balanceState.storedCashBalance.add(balanceState.netCashChange).add(
                    balanceState.netAssetTransferInternalPrecision
                );

            if (totalCash > assetAmountInternal) {
                // Sufficient total cash to account for the deposit so no transfer is necessary
                return (assetAmountInternal, 0);
            } else if (totalCash > 0) {
                // Set the remainder as the transfer amount
                assetAmountExternal = token.convertToExternal(assetAmountInternal.sub(totalCash));
            }
        }

        if (token.hasTransferFee) {
            // If the token has a transfer fee the deposit amount may not equal the actual amount
            // that the contract will receive. We handle the deposit here and then update the netCashChange
            // accordingly which is denominated in internal precision.
            int256 assetAmountExternalPrecisionFinal = token.transfer(account, assetAmountExternal);
            // Convert the external precision to internal, it's possible that we lose dust amounts here but
            // this is unavoidable because we do not know how transfer fees are calculated.
            assetAmountTransferred = token.convertToInternal(assetAmountExternalPrecisionFinal);
            balanceState.netCashChange = balanceState.netCashChange.add(assetAmountTransferred);

            // This is the total amount change accounting for the transfer fee.
            assetAmountInternal = assetAmountInternal.sub(
                token.convertToInternal(assetAmountExternal.sub(assetAmountExternalPrecisionFinal))
            );

            return (assetAmountInternal, assetAmountTransferred);
        }

        // Otherwise add the asset amount here. It may be net off later and we want to only do
        // a single transfer during the finalize method. Use internal precision to ensure that internal accounting
        // and external account remain in sync.
        assetAmountTransferred = token.convertToInternal(assetAmountExternal);
        balanceState.netAssetTransferInternalPrecision = balanceState
            .netAssetTransferInternalPrecision
            .add(assetAmountTransferred);

        // Returns the converted assetAmountExternal to the internal amount
        return (assetAmountInternal, assetAmountTransferred);
    }

    /// @notice Handle deposits of the underlying token
    /// @dev In this case we must wrap the underlying token into an asset token, ensuring that we do not end up
    /// with any underlying tokens left as dust on the contract.
    function depositUnderlyingToken(
        BalanceState memory balanceState,
        address account,
        int256 underlyingAmountExternal
    ) internal returns (int256) {
        if (underlyingAmountExternal == 0) return 0;
        require(underlyingAmountExternal > 0); // dev: deposit underlying token nevative

        Token memory underlyingToken = TokenHandler.getToken(balanceState.currencyId, true);
        // This is the exact amount of underlying tokens the account has in external precision.
        if (underlyingToken.tokenType == TokenType.Ether) {
            underlyingAmountExternal = int256(msg.value);
        } else {
            underlyingAmountExternal = underlyingToken.transfer(account, underlyingAmountExternal);
        }

        Token memory assetToken = TokenHandler.getToken(balanceState.currencyId, false);
        // Tokens that are not mintable like cTokens will be deposited as assetTokens
        require(assetToken.tokenType == TokenType.cToken || assetToken.tokenType == TokenType.cETH); // dev: deposit underlying token invalid token type
        int256 assetTokensReceivedExternalPrecision =
            assetToken.mint(uint256(underlyingAmountExternal));

        // cTokens match INTERNAL_TOKEN_PRECISION so this will short circuit but we leave this here in case a different
        // type of asset token is listed in the future. It's possible if those tokens have a different precision dust may
        // accrue but that is not relevant now.
        int256 assetTokensReceivedInternal =
            assetToken.convertToInternal(assetTokensReceivedExternalPrecision);
        balanceState.netCashChange = balanceState.netCashChange.add(assetTokensReceivedInternal);

        return assetTokensReceivedInternal;
    }

    /// @notice Finalizes an account's balances, handling any transfer logic required
    /// @dev This method SHOULD NOT be used for perpetual token accounts, for that use setBalanceStorageForNToken
    /// as the perp token is limited in what types of balances it can hold.
    function finalize(
        BalanceState memory balanceState,
        address account,
        AccountStorage memory accountContext,
        bool redeemToUnderlying
    ) internal returns (int256 transferAmountExternal) {
        bool mustUpdate;
        if (balanceState.netPerpetualTokenTransfer < 0) {
            require(
                balanceState.storedPerpetualTokenBalance.add(
                    balanceState.netPerpetualTokenSupplyChange
                ) >= balanceState.netPerpetualTokenTransfer.neg(),
                "BH: cannot withdraw negative"
            );
        }

        if (balanceState.netAssetTransferInternalPrecision < 0) {
            require(
                balanceState.storedCashBalance.add(balanceState.netCashChange).add(
                    balanceState.netAssetTransferInternalPrecision
                ) >= 0,
                "BH: cannot withdraw negative"
            );
        }

        if (balanceState.netAssetTransferInternalPrecision != 0) {
            transferAmountExternal = _finalizeTransfers(balanceState, account, redeemToUnderlying);
        }

        if (
            balanceState.netCashChange != 0 || balanceState.netAssetTransferInternalPrecision != 0
        ) {
            balanceState.storedCashBalance = balanceState
                .storedCashBalance
                .add(balanceState.netCashChange)
                .add(balanceState.netAssetTransferInternalPrecision);

            mustUpdate = true;
        }

        if (
            balanceState.netPerpetualTokenTransfer != 0 ||
            balanceState.netPerpetualTokenSupplyChange != 0
        ) {
            // It's crucial that incentives are claimed before we do any sort of nToken transfer to prevent gaming
            // of the system. This method will update the lastIncentiveClaim time in the balanceState for storage.
            Incentives.claimIncentives(balanceState, account);

            // Perpetual tokens are within the notional system so we can update balances directly.
            balanceState.storedPerpetualTokenBalance = balanceState
                .storedPerpetualTokenBalance
                .add(balanceState.netPerpetualTokenTransfer)
                .add(balanceState.netPerpetualTokenSupplyChange);

            mustUpdate = true;
        }

        if (mustUpdate) {
            _setBalanceStorage(
                account,
                balanceState.currencyId,
                balanceState.storedCashBalance,
                balanceState.storedPerpetualTokenBalance,
                balanceState.lastIncentiveClaim
            );
        }

        accountContext.setActiveCurrency(
            balanceState.currencyId,
            // Set active currency to true if either balance is non-zero
            balanceState.storedCashBalance != 0 || balanceState.storedPerpetualTokenBalance != 0,
            AccountContextHandler.ACTIVE_IN_BALANCES_FLAG
        );

        if (balanceState.storedCashBalance < 0) {
            // NOTE: HAS_CASH_DEBT cannot be extinguished except by a free collateral check where all balances
            // are examined
            accountContext.hasDebt = accountContext.hasDebt | AccountContextHandler.HAS_CASH_DEBT;
        }

        return transferAmountExternal;
    }

    function _finalizeTransfers(
        BalanceState memory balanceState,
        address account,
        bool redeemToUnderlying
    ) private returns (int256 transferAmountExternal) {
        Token memory assetToken = TokenHandler.getToken(balanceState.currencyId, false);
        transferAmountExternal = assetToken.convertToExternal(
            balanceState.netAssetTransferInternalPrecision
        );

        if (redeemToUnderlying) {
            // We use the internal amount here and then scale it to the external amount so that there is
            // no loss of precision between our internal accounting and the external account. In this case
            // there will be no dust accrual since we will transfer the exact amount of underlying that was
            // received.
            require(transferAmountExternal < 0); // dev: invalid redeem balance
            Token memory underlyingToken = TokenHandler.getToken(balanceState.currencyId, true);
            int256 underlyingAmountExternal =
                assetToken.redeem(
                    underlyingToken,
                    // NOTE: dust may accrue at the lowest decimal place
                    uint256(transferAmountExternal.neg())
                );

            // Withdraws the underlying amount out to the destination account
            underlyingToken.transfer(account, underlyingAmountExternal.neg());
        } else {
            transferAmountExternal = assetToken.transfer(account, transferAmountExternal);
        }

        // Convert the actual transferred amount
        balanceState.netAssetTransferInternalPrecision = assetToken.convertToInternal(
            transferAmountExternal
        );

        return transferAmountExternal;
    }

    /// @notice Special method for settling negative current cash debts. This occurs when an account
    /// has a negative fCash balance settle to cash. A settler may come and force the account to borrow
    /// at the prevailing 3 month rate
    /// @dev Use this method to avoid any nToken and transfer logic in finalize which is unncessary.
    function setBalanceStorageForSettleCashDebt(
        address account,
        CashGroupParameters memory cashGroup,
        int256 amountToSettleAsset,
        AccountStorage memory accountContext
    ) internal returns (int256) {
        require(amountToSettleAsset >= 0); // dev: amount to settle negative
        (int256 cashBalance, int256 nTokenBalance, uint256 lastIncentiveClaim) =
            getBalanceStorage(account, cashGroup.currencyId);

        require(cashBalance < 0, "Invalid settle balance");
        if (amountToSettleAsset == 0) {
            // Symbolizes that the entire debt should be settled
            amountToSettleAsset = cashBalance.neg();
            cashBalance = 0;
        } else {
            // A partial settlement of the debt
            require(amountToSettleAsset <= cashBalance.neg(), "Invalid amount to settle");
            cashBalance = cashBalance.add(amountToSettleAsset);
        }

        // NOTE: we do not update HAS_CASH_DEBT here because it is possible that the other balances
        // also have cash debts
        if (cashBalance == 0) {
            accountContext.setActiveCurrency(
                cashGroup.currencyId,
                false,
                AccountContextHandler.ACTIVE_IN_BALANCES_FLAG
            );
        }

        _setBalanceStorage(
            account,
            cashGroup.currencyId,
            cashBalance,
            nTokenBalance,
            lastIncentiveClaim
        );

        return amountToSettleAsset;
    }

    /// @notice Helper method for settling the output of the SettleAssets method
    function finalizeSettleAmounts(
        address account,
        AccountStorage memory accountContext,
        SettleAmount[] memory settleAmounts
    ) internal {
        for (uint256 i; i < settleAmounts.length; i++) {
            if (settleAmounts[i].netCashChange == 0) continue;

            (int256 cashBalance, int256 nTokenBalance, uint256 lastIncentiveClaim) =
                getBalanceStorage(account, settleAmounts[i].currencyId);

            cashBalance = cashBalance.add(settleAmounts[i].netCashChange);
            accountContext.setActiveCurrency(
                settleAmounts[i].currencyId,
                cashBalance != 0 || nTokenBalance != 0,
                AccountContextHandler.ACTIVE_IN_BALANCES_FLAG
            );

            if (cashBalance < 0) {
                accountContext.hasDebt =
                    accountContext.hasDebt |
                    AccountContextHandler.HAS_CASH_DEBT;
            }

            _setBalanceStorage(
                account,
                settleAmounts[i].currencyId,
                cashBalance,
                nTokenBalance,
                lastIncentiveClaim
            );
        }
    }

    /// @notice Special method for setting balance storage for nToken
    function setBalanceStorageForNToken(
        address nTokenAddress,
        uint256 currencyId,
        int256 cashBalance
    ) internal {
        require(cashBalance >= 0); // dev: invalid perp token cash balance
        _setBalanceStorage(nTokenAddress, currencyId, cashBalance, 0, 0);
    }

    /// @notice increments fees to the reserve
    function incrementFeeToReserve(uint256 currencyId, int256 fee) internal {
        require(fee >= 0); // dev: invalid fee
        // prettier-ignore
        (int256 totalReserve, /* */, /* */) = getBalanceStorage(Constants.RESERVE, currencyId);
        totalReserve = totalReserve.add(fee);
        _setBalanceStorage(Constants.RESERVE, currencyId, totalReserve, 0, 0);
    }

    /// @notice Sets internal balance storage.
    function _setBalanceStorage(
        address account,
        uint256 currencyId,
        int256 cashBalance,
        int256 nTokenBalance,
        uint256 lastIncentiveClaim
    ) private {
        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));
        require(cashBalance >= type(int128).min && cashBalance <= type(int128).max); // dev: stored cash balance overflow
        require(nTokenBalance >= 0 && nTokenBalance <= type(uint96).max); // dev: stored perpetual token balance overflow
        require(lastIncentiveClaim >= 0 && lastIncentiveClaim <= type(uint32).max); // dev: last incentive claim overflow

        bytes32 data =
            ((bytes32(uint256(nTokenBalance))) |
                (bytes32(lastIncentiveClaim) << 96) |
                (bytes32(cashBalance) << 128));

        assembly {
            sstore(slot, data)
        }
    }

    /// @notice Gets internal balance storage, perpetual tokens are stored alongside cash balances
    function getBalanceStorage(address account, uint256 currencyId)
        internal
        view
        returns (
            int256 cashBalance,
            int256 nTokenBalance,
            uint256 lastIncentiveClaim
        )
    {
        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        cashBalance = int256(int128(int256(data >> 128)));
        nTokenBalance = int256(uint96(uint256(data)));
        lastIncentiveClaim = uint256(uint32(uint256(data >> 96)));
    }

    /// @notice Loads a balance state memory object
    /// @dev Balance state objects occupy a lot of memory slots, so this method allows
    /// us to reuse them if possible
    function loadBalanceState(
        BalanceState memory balanceState,
        address account,
        uint256 currencyId,
        AccountStorage memory accountContext
    ) internal view {
        require(currencyId != 0, "BH: invalid currency id");
        balanceState.currencyId = currencyId;

        if (accountContext.isActiveInBalances(currencyId)) {
            (
                balanceState.storedCashBalance,
                balanceState.storedPerpetualTokenBalance,
                balanceState.lastIncentiveClaim
            ) = getBalanceStorage(account, currencyId);
        } else {
            balanceState.storedCashBalance = 0;
            balanceState.storedPerpetualTokenBalance = 0;
            balanceState.lastIncentiveClaim = 0;
        }

        balanceState.netCashChange = 0;
        balanceState.netAssetTransferInternalPrecision = 0;
        balanceState.netPerpetualTokenTransfer = 0;
        balanceState.netPerpetualTokenSupplyChange = 0;
    }

    /// @notice Used when manually claiming incentives in nTokenAction
    function claimIncentivesManual(BalanceState memory balanceState, address account)
        internal
        returns (uint256)
    {
        uint256 incentivesClaimed = Incentives.claimIncentives(balanceState, account);
        _setBalanceStorage(
            account,
            balanceState.currencyId,
            balanceState.storedCashBalance,
            balanceState.storedPerpetualTokenBalance,
            balanceState.lastIncentiveClaim
        );

        return incentivesClaimed;
    }
}
