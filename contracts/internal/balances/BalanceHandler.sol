// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./Incentives.sol";
import "./TokenHandler.sol";
import "../AccountContextHandler.sol";
import "../../global/Types.sol";
import "../../global/Constants.sol";
import "../../math/SafeInt256.sol";
import "../../math/FloatingPoint56.sol";

library BalanceHandler {
    using SafeInt256 for int256;
    using TokenHandler for Token;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountContext;

    /// @notice Emitted when a cash balance changes
    event CashBalanceChange(address indexed account, uint16 indexed currencyId, int256 netCashChange);
    /// @notice Emitted when nToken supply changes (not the same as transfers)
    event nTokenSupplyChange(address indexed account, uint16 indexed currencyId, int256 tokenSupplyChange);

    /// @notice Deposits asset tokens into an account
    /// @dev Handles two special cases when depositing tokens into an account.
    ///  - If a token has transfer fees then the amount specified does not equal the amount that the contract
    ///    will receive. Complete the deposit here rather than in finalize so that the contract has the correct
    ///    balance to work with.
    ///  - Force a transfer before finalize to allow a different account to deposit into an account
    /// @return Returns two values:
    ///  - assetAmountInternal which is the converted asset amount accounting for transfer fees
    ///  - assetAmountTransferred which is the internal precision amount transferred into the account
    function depositAssetToken(
        BalanceState memory balanceState,
        address account,
        int256 assetAmountExternal,
        bool forceTransfer
    ) internal returns (int256) {
        if (assetAmountExternal == 0) return 0;
        require(assetAmountExternal > 0); // dev: deposit asset token amount negative
        Token memory token = TokenHandler.getAssetToken(balanceState.currencyId);
        int256 assetAmountInternal = token.convertToInternal(assetAmountExternal);

        // Force transfer is used to complete the transfer before going to finalize
        if (token.hasTransferFee || forceTransfer) {
            // If the token has a transfer fee the deposit amount may not equal the actual amount
            // that the contract will receive. We handle the deposit here and then update the netCashChange
            // accordingly which is denominated in internal precision.
            int256 assetAmountExternalPrecisionFinal = token.transfer(account, assetAmountExternal);
            // Convert the external precision to internal, it's possible that we lose dust amounts here but
            // this is unavoidable because we do not know how transfer fees are calculated.
            assetAmountInternal = token.convertToInternal(assetAmountExternalPrecisionFinal);
            // @audit-ok transfer has been called
            balanceState.netCashChange = balanceState.netCashChange.add(assetAmountInternal);

            return assetAmountInternal;
        } else {
            // Otherwise add the asset amount here. It may be net off later and we want to only do
            // a single transfer during the finalize method. Use internal precision to ensure that internal accounting
            // and external account remain in sync.
            // @audit-ok transfer will be deferred
            balanceState.netAssetTransferInternalPrecision = balanceState
                .netAssetTransferInternalPrecision
                .add(assetAmountInternal);

            // Returns the converted assetAmountExternal to the internal amount
            return assetAmountInternal;
        }
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
        require(underlyingAmountExternal > 0); // dev: deposit underlying token negative

        // @audit change getter to getUnderlyingToken or getAssetToken
        // @audit-ok gets the underlying token
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(balanceState.currencyId);
        // This is the exact amount of underlying tokens the account has in external precision.
        if (underlyingToken.tokenType == TokenType.Ether) {
            // @audit-ok underflow checked above
            require(uint256(underlyingAmountExternal) == msg.value, "ETH Balance");
        } else {
            underlyingAmountExternal = underlyingToken.transfer(account, underlyingAmountExternal);
        }

        // @audit-ok gets the asset token
        Token memory assetToken = TokenHandler.getAssetToken(balanceState.currencyId);
        // Tokens that are not mintable like cTokens will be deposited as assetTokens
        require(assetToken.tokenType == TokenType.cToken || assetToken.tokenType == TokenType.cETH); // dev: deposit underlying token invalid token type
        int256 assetTokensReceivedExternalPrecision =
            assetToken.mint(SafeInt256.toUint(underlyingAmountExternal));

        // cTokens match INTERNAL_TOKEN_PRECISION so this will short circuit but we leave this here in case a different
        // type of asset token is listed in the future. It's possible if those tokens have a different precision dust may
        // accrue but that is not relevant now.
        int256 assetTokensReceivedInternal =
            assetToken.convertToInternal(assetTokensReceivedExternalPrecision);
        // @audit-ok transfer / mint has taken effect
        balanceState.netCashChange = balanceState.netCashChange.add(assetTokensReceivedInternal);

        return assetTokensReceivedInternal;
    }

    /// @notice Finalizes an account's balances, handling any transfer logic required
    /// @dev This method SHOULD NOT be used for nToken accounts, for that use setBalanceStorageForNToken
    /// as the nToken is limited in what types of balances it can hold.
    function finalize(
        BalanceState memory balanceState,
        address account,
        AccountContext memory accountContext,
        bool redeemToUnderlying
    ) internal returns (int256 transferAmountExternal) {
        bool mustUpdate;
        if (balanceState.netNTokenTransfer < 0) {
            // @audit-ok
            require(
                balanceState.storedNTokenBalance
                    .add(balanceState.netNTokenSupplyChange)
                    .add(balanceState.netNTokenTransfer) >= 0,
                "Neg nToken"
            );
        }

        // @audit-ok
        if (balanceState.netAssetTransferInternalPrecision < 0) {
            require(
                balanceState.storedCashBalance
                    .add(balanceState.netCashChange)
                    .add(balanceState.netAssetTransferInternalPrecision) >= 0,
                "Neg Cash"
            );
        }

        // Transfer amount is checked inside finalize transfers in case when converting to external we
        // round down to zero. This returns the actual net transfer in internal precision as well.
        (
            transferAmountExternal,
            balanceState.netAssetTransferInternalPrecision
        ) = _finalizeTransfers(balanceState, account, redeemToUnderlying);
        // @audit-ok no changes to total cash after this point
        int256 totalCashChange = balanceState.netCashChange.add(balanceState.netAssetTransferInternalPrecision);

        if (totalCashChange != 0) {
            // @audit-ok
            balanceState.storedCashBalance = balanceState.storedCashBalance.add(totalCashChange);
            mustUpdate = true;

            emit CashBalanceChange(
                account,
                uint16(balanceState.currencyId),
                totalCashChange
            );
        }

        if (balanceState.netNTokenTransfer != 0 || balanceState.netNTokenSupplyChange != 0) {
            // @audit-ok
            // It's crucial that incentives are claimed before we do any sort of nToken transfer to prevent gaming
            // of the system. This method will update the lastClaimTime time and lastIntegralTotalSupply in balance
            // state in place.
            Incentives.claimIncentives(balanceState, account);

            // nTokens are within the notional system so we can update balances directly.
            balanceState.storedNTokenBalance = balanceState
                .storedNTokenBalance
                .add(balanceState.netNTokenTransfer)
                .add(balanceState.netNTokenSupplyChange);

            if (balanceState.netNTokenSupplyChange != 0) {
                emit nTokenSupplyChange(
                    account,
                    uint16(balanceState.currencyId),
                    balanceState.netNTokenSupplyChange
                );
            }

            mustUpdate = true;
        }

        if (mustUpdate) {
            // @audit-ok all balances have updated by now
            _setBalanceStorage(
                account,
                balanceState.currencyId,
                balanceState.storedCashBalance,
                balanceState.storedNTokenBalance,
                balanceState.lastClaimTime,
                balanceState.lastClaimIntegralSupply
            );
        }

        // @audit-ok
        accountContext.setActiveCurrency(
            balanceState.currencyId,
            // Set active currency to true if either balance is non-zero
            balanceState.storedCashBalance != 0 || balanceState.storedNTokenBalance != 0,
            Constants.ACTIVE_IN_BALANCES
        );

        // @audit-ok
        if (balanceState.storedCashBalance < 0) {
            // NOTE: HAS_CASH_DEBT cannot be extinguished except by a free collateral check where all balances
            // are examined
            accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_CASH_DEBT;
        }
    }

    /// @dev Returns the amount transferred in underlying or asset terms depending on how redeem to underlying
    /// is specified.
    function _finalizeTransfers(
        BalanceState memory balanceState,
        address account,
        bool redeemToUnderlying
    ) private returns (int256 actualTransferAmountExternal, int256 assetTransferAmountInternal) {
        Token memory assetToken = TokenHandler.getAssetToken(balanceState.currencyId);
        // Dust accrual to the protocol is possible if the token decimals is less than internal token precision.
        // See the comments in TokenHandler.convertToExternal and TokenHandler.convertToInternal
        int256 assetTransferAmountExternal =
            assetToken.convertToExternal(balanceState.netAssetTransferInternalPrecision);

        if (assetTransferAmountExternal == 0) {
            return (0, 0);
        } else if (redeemToUnderlying && assetTransferAmountExternal < 0) {
            // We only do the redeem to underlying if the asset transfer amount is less than zero. If it is greater than
            // zero then we will do a normal transfer instead.

            // We use the internal amount here and then scale it to the external amount so that there is
            // no loss of precision between our internal accounting and the external account. In this case
            // there will be no dust accrual in underlying tokens since we will transfer the exact amount
            // of underlying that was received.
            Token memory underlyingToken = TokenHandler.getUnderlyingToken(balanceState.currencyId);
            // @audit underlyingAmountExternal is converted from uint to int inside, must be positive
            int256 underlyingAmountExternal = assetToken.redeem(
                underlyingToken,
                uint256(assetTransferAmountExternal.neg())
            );

            // Withdraws the underlying amount out to the destination account
            // @audit-ok this is guaranteed to be a withdraw
            actualTransferAmountExternal = underlyingToken.transfer(
                account,
                underlyingAmountExternal.neg()
            );
            // @audit-ok in this case we're transferring underlying tokens, we want to convert the internal
            // asset transfer amount to store in cash balances
            assetTransferAmountInternal = assetToken.convertToInternal(assetTransferAmountExternal);
        } else {
            // @audit-ok this is the actual transfer amount
            actualTransferAmountExternal = assetToken.transfer(account, assetTransferAmountExternal);
            // Convert the actual transferred amount
            // @audit-ok in this case we're transferring asset tokens
            assetTransferAmountInternal = assetToken.convertToInternal(actualTransferAmountExternal);
        }
    }

    /// @notice Special method for settling negative current cash debts. This occurs when an account
    /// has a negative fCash balance settle to cash. A settler may come and force the account to borrow
    /// at the prevailing 3 month rate
    /// @dev Use this method to avoid any nToken and transfer logic in finalize which is unnecessary.
    function setBalanceStorageForSettleCashDebt(
        address account,
        CashGroupParameters memory cashGroup,
        int256 amountToSettleAsset,
        AccountContext memory accountContext
    ) internal returns (int256) {
        require(amountToSettleAsset >= 0); // dev: amount to settle negative
        // @audit using storage slot directly would be more reliable here
        (int256 cashBalance, int256 nTokenBalance, uint256 lastClaimTime, uint256 lastClaimIntegralSupply) =
            getBalanceStorage(account, cashGroup.currencyId);

        // @audit-ok this prevents settlement of positive balances
        require(cashBalance < 0, "Invalid settle balance");
        if (amountToSettleAsset == 0) {
            // Symbolizes that the entire debt should be settled
            amountToSettleAsset = cashBalance.neg();
            cashBalance = 0;
        } else {
            // A partial settlement of the debt
            require(amountToSettleAsset <= cashBalance.neg(), "Invalid amount to settle");
            // @audit-ok this is the partial settlement amount
            cashBalance = cashBalance.add(amountToSettleAsset);
        }

        // NOTE: we do not update HAS_CASH_DEBT here because it is possible that the other balances
        // also have cash debts
        // @audit-ok checks both cash and nToken balance
        if (cashBalance == 0 && nTokenBalance == 0) {
            accountContext.setActiveCurrency(
                cashGroup.currencyId,
                false,
                Constants.ACTIVE_IN_BALANCES
            );
        }

        // @audit-ok immediately update the storage here
        _setBalanceStorage(
            account,
            cashGroup.currencyId,
            cashBalance,
            nTokenBalance,
            lastClaimTime,
            lastClaimIntegralSupply
        );

        // Emit the event here, we do not call finalize
        // @audit-ok currency id cannot overflow, we don't have ids > uint16
        emit CashBalanceChange(account, uint16(cashGroup.currencyId), amountToSettleAsset);

        return amountToSettleAsset;
    }

    /// @notice Helper method for settling the output of the SettleAssets method
    function finalizeSettleAmounts(
        address account,
        AccountContext memory accountContext,
        SettleAmount[] memory settleAmounts
    ) internal {
        for (uint256 i = 0; i < settleAmounts.length; i++) {
            SettleAmount memory amt = settleAmounts[i];
            if (amt.netCashChange == 0) continue;

            (
                int256 cashBalance,
                int256 nTokenBalance,
                uint256 lastClaimTime,
                uint256 lastClaimIntegralSupply
            ) = getBalanceStorage(account, amt.currencyId);

            // @audit-ok
            cashBalance = cashBalance.add(amt.netCashChange);
            accountContext.setActiveCurrency(
                amt.currencyId,
                cashBalance != 0 || nTokenBalance != 0,
                Constants.ACTIVE_IN_BALANCES
            );

            // @audit-ok
            if (cashBalance < 0) {
                accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_CASH_DEBT;
            }

            emit CashBalanceChange(
                account,
                uint16(amt.currencyId),
                amt.netCashChange
            );

            // @audit-ok
            _setBalanceStorage(
                account,
                amt.currencyId,
                cashBalance,
                nTokenBalance,
                lastClaimTime,
                lastClaimIntegralSupply
            );
        }
    }

    /// @notice Special method for setting balance storage for nToken
    function setBalanceStorageForNToken(
        address nTokenAddress,
        uint256 currencyId,
        int256 cashBalance
    ) internal {
        // @audit consider moving this to its own storage slot
        require(cashBalance >= 0); // dev: invalid nToken cash balance
        _setBalanceStorage(nTokenAddress, currencyId, cashBalance, 0, 0, 0);
    }

    /// @notice increments fees to the reserve
    function incrementFeeToReserve(uint256 currencyId, int256 fee) internal {
        // @audit consider moving this to its own storage slot
        require(fee >= 0); // dev: invalid fee
        // prettier-ignore
        (int256 totalReserve, /* */, /* */, /* */) = getBalanceStorage(Constants.RESERVE, currencyId);
        totalReserve = totalReserve.add(fee);
        _setBalanceStorage(Constants.RESERVE, currencyId, totalReserve, 0, 0, 0);
    }

    function _getSlot(address account, uint256 currencyId) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    currencyId,
                    keccak256(abi.encode(account, Constants.BALANCE_STORAGE_OFFSET))
                )
            );
    }

    /// @notice Sets internal balance storage.
    function _setBalanceStorage(
        address account,
        uint256 currencyId,
        int256 cashBalance,
        int256 nTokenBalance,
        uint256 lastClaimTime,
        uint256 lastClaimIntegralSupply
    ) private {
        bytes32 slot = _getSlot(account, currencyId);
        require(cashBalance >= type(int88).min && cashBalance <= type(int88).max); // dev: stored cash balance overflow
        // Allows for 12 quadrillion nToken balance in 1e8 decimals before overflow
        require(nTokenBalance >= 0 && nTokenBalance <= type(uint80).max); // dev: stored nToken balance overflow
        require(lastClaimTime <= type(uint32).max); // dev: last claim time overflow
        // Last claim supply is stored in a "floating point" storage slot that does not maintain exact precision but
        // is also not limited by storage overflows. `packTo56Bits` will ensure that the the returned value will fit
        // in 56 bits (7 bytes)
        bytes32 packedLastClaimIntegralSupply = FloatingPoint56.packTo56Bits(lastClaimIntegralSupply);

        // @audit-ok
        bytes32 data =
            ((bytes32(uint256(nTokenBalance))) |
            // 80 bits
                (bytes32(lastClaimTime) << 80) |
            // 80 + 32 = 112
                (packedLastClaimIntegralSupply << 112) |
            // 80 + 32 + 56 = 112
                (bytes32(cashBalance) << 168));

        assembly {
            sstore(slot, data)
        }
    }

    /// @notice Gets internal balance storage, nTokens are stored alongside cash balances
    function getBalanceStorage(address account, uint256 currencyId)
        internal
        view
        returns (
            int256 cashBalance,
            int256 nTokenBalance,
            uint256 lastClaimTime,
            uint256 lastClaimIntegralSupply
        )
    {
        bytes32 slot = _getSlot(account, currencyId);
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        // @audit-ok
        nTokenBalance = uint80(uint256(data));
        lastClaimTime = uint32(uint256(data >> 80));
        lastClaimIntegralSupply = FloatingPoint56.unpackFrom56Bits(uint56(uint256(data >> 112)));
        cashBalance = int88(int256(data >> 168));
    }

    /// @notice Loads a balance state memory object
    /// @dev Balance state objects occupy a lot of memory slots, so this method allows
    /// us to reuse them if possible
    function loadBalanceState(
        BalanceState memory balanceState,
        address account,
        uint256 currencyId,
        AccountContext memory accountContext
    ) internal view {
        require(0 < currencyId && currencyId <= Constants.MAX_CURRENCIES); // dev: invalid currency id
        balanceState.currencyId = currencyId;
        // @audit-ok

        if (accountContext.isActiveInBalances(currencyId)) {
            (
                balanceState.storedCashBalance,
                balanceState.storedNTokenBalance,
                balanceState.lastClaimTime,
                balanceState.lastClaimIntegralSupply
            ) = getBalanceStorage(account, currencyId);
        } else {
            balanceState.storedCashBalance = 0;
            balanceState.storedNTokenBalance = 0;
            balanceState.lastClaimTime = 0;
            balanceState.lastClaimIntegralSupply = 0;
        }

        balanceState.netCashChange = 0;
        balanceState.netAssetTransferInternalPrecision = 0;
        balanceState.netNTokenTransfer = 0;
        balanceState.netNTokenSupplyChange = 0;
    }

    /// @notice Used when manually claiming incentives in nTokenAction. Also sets the balance state
    /// to storage to update the lastClaimTime and lastClaimIntegralSupply
    function claimIncentivesManual(BalanceState memory balanceState, address account)
        internal
        returns (uint256)
    {
        // @audit maybe have this take a currency id instead of a balance state so that we don't
        // update cash balances in an unintended way...
        uint256 incentivesClaimed = Incentives.claimIncentives(balanceState, account);
        _setBalanceStorage(
            account,
            balanceState.currencyId,
            balanceState.storedCashBalance,
            balanceState.storedNTokenBalance,
            balanceState.lastClaimTime,
            balanceState.lastClaimIntegralSupply
        );

        return incentivesClaimed;
    }
}
