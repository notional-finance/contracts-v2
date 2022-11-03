// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
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
    /// @notice Emitted when reserve fees are accrued
    event ReserveFeeAccrued(uint16 indexed currencyId, int256 fee);
    /// @notice Emitted when reserve balance is updated
    event ReserveBalanceUpdated(uint16 indexed currencyId, int256 newBalance);
    /// @notice Emitted when reserve balance is harvested
    event ExcessReserveBalanceHarvested(uint16 indexed currencyId, int256 harvestAmount);

    /// @notice Deposits asset tokens into an account
    /// @dev Handles two special cases when depositing tokens into an account.
    ///  - If a token has transfer fees then the amount specified does not equal the amount that the contract
    ///    will receive. Complete the deposit here rather than in finalize so that the contract has the correct
    ///    balance to work with.
    ///  - Force a transfer before finalize to allow a different account to deposit into an account
    /// @return assetAmountInternal which is the converted asset amount accounting for transfer fees
    function depositAssetToken(
        BalanceState memory balanceState,
        address account,
        int256 assetAmountExternal,
        bool forceTransfer
    ) internal returns (int256 assetAmountInternal) {
        if (assetAmountExternal == 0) return 0;
        require(assetAmountExternal > 0); // dev: deposit asset token amount negative
        Token memory token = TokenHandler.getAssetToken(balanceState.currencyId);
        if (token.tokenType == TokenType.aToken) {
            // Handles special accounting requirements for aTokens
            assetAmountExternal = AaveHandler.convertToScaledBalanceExternal(
                balanceState.currencyId,
                assetAmountExternal
            );
        }

        // Force transfer is used to complete the transfer before going to finalize
        if (token.hasTransferFee || forceTransfer) {
            // If the token has a transfer fee the deposit amount may not equal the actual amount
            // that the contract will receive. We handle the deposit here and then update the netCashChange
            // accordingly which is denominated in internal precision.
            int256 assetAmountExternalPrecisionFinal = token.transfer(account, balanceState.currencyId, assetAmountExternal);
            // Convert the external precision to internal, it's possible that we lose dust amounts here but
            // this is unavoidable because we do not know how transfer fees are calculated.
            assetAmountInternal = token.convertToInternal(assetAmountExternalPrecisionFinal);
            // Transfer has been called
            balanceState.netCashChange = balanceState.netCashChange.add(assetAmountInternal);

            return assetAmountInternal;
        } else {
            assetAmountInternal = token.convertToInternal(assetAmountExternal);
            // Otherwise add the asset amount here. It may be net off later and we want to only do
            // a single transfer during the finalize method. Use internal precision to ensure that internal accounting
            // and external account remain in sync.
            // Transfer will be deferred
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

        Token memory underlyingToken = TokenHandler.getUnderlyingToken(balanceState.currencyId);
        // This is the exact amount of underlying tokens the account has in external precision.
        if (underlyingToken.tokenType == TokenType.Ether) {
            // Underflow checked above
            require(uint256(underlyingAmountExternal) == msg.value, "ETH Balance");
        } else {
            underlyingAmountExternal = underlyingToken.transfer(account, balanceState.currencyId, underlyingAmountExternal);
        }

        Token memory assetToken = TokenHandler.getAssetToken(balanceState.currencyId);
        int256 assetTokensReceivedExternalPrecision =
            assetToken.mint(balanceState.currencyId, SafeInt256.toUint(underlyingAmountExternal));

        // cTokens match INTERNAL_TOKEN_PRECISION so this will short circuit but we leave this here in case a different
        // type of asset token is listed in the future. It's possible if those tokens have a different precision dust may
        // accrue but that is not relevant now.
        int256 assetTokensReceivedInternal =
            assetToken.convertToInternal(assetTokensReceivedExternalPrecision);
        // Transfer / mint has taken effect
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
            require(
                balanceState.storedNTokenBalance
                    .add(balanceState.netNTokenSupplyChange)
                    .add(balanceState.netNTokenTransfer) >= 0,
                "Neg nToken"
            );
        }

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
        // No changes to total cash after this point
        int256 totalCashChange = balanceState.netCashChange.add(balanceState.netAssetTransferInternalPrecision);

        if (totalCashChange != 0) {
            balanceState.storedCashBalance = balanceState.storedCashBalance.add(totalCashChange);
            mustUpdate = true;

            emit CashBalanceChange(
                account,
                uint16(balanceState.currencyId),
                totalCashChange
            );
        }

        if (balanceState.netNTokenTransfer != 0 || balanceState.netNTokenSupplyChange != 0) {
            // Final nToken balance is used to calculate the account incentive debt
            int256 finalNTokenBalance = balanceState.storedNTokenBalance
                .add(balanceState.netNTokenTransfer)
                .add(balanceState.netNTokenSupplyChange);

            // The toUint() call here will ensure that nToken balances never become negative
            Incentives.claimIncentives(balanceState, account, finalNTokenBalance.toUint());

            balanceState.storedNTokenBalance = finalNTokenBalance;

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
            _setBalanceStorage(
                account,
                balanceState.currencyId,
                balanceState.storedCashBalance,
                balanceState.storedNTokenBalance,
                balanceState.lastClaimTime,
                balanceState.accountIncentiveDebt
            );
        }

        accountContext.setActiveCurrency(
            balanceState.currencyId,
            // Set active currency to true if either balance is non-zero
            balanceState.storedCashBalance != 0 || balanceState.storedNTokenBalance != 0,
            Constants.ACTIVE_IN_BALANCES
        );

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

            actualTransferAmountExternal = assetToken.redeem(
                balanceState.currencyId,
                account,
                // No overflow, checked above
                uint256(assetTransferAmountExternal.neg())
            );

            // In this case we're transferring underlying tokens, we want to convert the internal
            // asset transfer amount to store in cash balances
            assetTransferAmountInternal = assetToken.convertToInternal(assetTransferAmountExternal);
        } else {
            // NOTE: in the case of aTokens assetTransferAmountExternal is the scaledBalanceOf in external precision, it
            // will be converted to balanceOf denomination inside transfer
            actualTransferAmountExternal = assetToken.transfer(account, balanceState.currencyId, assetTransferAmountExternal);
            // Convert the actual transferred amount
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
        (int256 cashBalance, int256 nTokenBalance, uint256 lastClaimTime, uint256 accountIncentiveDebt) =
            getBalanceStorage(account, cashGroup.currencyId);

        // Prevents settlement of positive balances
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
        if (cashBalance == 0 && nTokenBalance == 0) {
            accountContext.setActiveCurrency(
                cashGroup.currencyId,
                false,
                Constants.ACTIVE_IN_BALANCES
            );
        }

        _setBalanceStorage(
            account,
            cashGroup.currencyId,
            cashBalance,
            nTokenBalance,
            lastClaimTime,
            accountIncentiveDebt
        );

        // Emit the event here, we do not call finalize
        emit CashBalanceChange(account, cashGroup.currencyId, amountToSettleAsset);

        return amountToSettleAsset;
    }

    /**
     * @notice A special balance storage method for fCash liquidation to reduce the bytecode size.
     */
    function setBalanceStorageForfCashLiquidation(
        address account,
        AccountContext memory accountContext,
        uint16 currencyId,
        int256 netCashChange
    ) internal {
        (int256 cashBalance, int256 nTokenBalance, uint256 lastClaimTime, uint256 accountIncentiveDebt) =
            getBalanceStorage(account, currencyId);

        int256 newCashBalance = cashBalance.add(netCashChange);
        // If a cash balance is negative already we cannot put an account further into debt. In this case
        // the netCashChange must be positive so that it is coming out of debt.
        if (newCashBalance < 0) {
            require(netCashChange > 0, "Neg Cash");
            // NOTE: HAS_CASH_DEBT cannot be extinguished except by a free collateral check
            // where all balances are examined. In this case the has cash debt flag should
            // already be set (cash balances cannot get more negative) but we do it again
            // here just to be safe.
            accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_CASH_DEBT;
        }

        bool isActive = newCashBalance != 0 || nTokenBalance != 0;
        accountContext.setActiveCurrency(currencyId, isActive, Constants.ACTIVE_IN_BALANCES);

        // Emit the event here, we do not call finalize
        emit CashBalanceChange(account, currencyId, netCashChange);

        _setBalanceStorage(
            account,
            currencyId,
            newCashBalance,
            nTokenBalance,
            lastClaimTime,
            accountIncentiveDebt
        );
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
                uint256 accountIncentiveDebt
            ) = getBalanceStorage(account, amt.currencyId);

            cashBalance = cashBalance.add(amt.netCashChange);
            accountContext.setActiveCurrency(
                amt.currencyId,
                cashBalance != 0 || nTokenBalance != 0,
                Constants.ACTIVE_IN_BALANCES
            );

            if (cashBalance < 0) {
                accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_CASH_DEBT;
            }

            emit CashBalanceChange(
                account,
                uint16(amt.currencyId),
                amt.netCashChange
            );

            _setBalanceStorage(
                account,
                amt.currencyId,
                cashBalance,
                nTokenBalance,
                lastClaimTime,
                accountIncentiveDebt
            );
        }
    }

    /// @notice Special method for setting balance storage for nToken
    function setBalanceStorageForNToken(
        address nTokenAddress,
        uint256 currencyId,
        int256 cashBalance
    ) internal {
        require(cashBalance >= 0); // dev: invalid nToken cash balance
        _setBalanceStorage(nTokenAddress, currencyId, cashBalance, 0, 0, 0);
    }

    /// @notice Asses a fee or a refund to the nToken for leveraged vaults
    function incrementVaultFeeToNToken(uint256 currencyId, int256 fee) internal {
        require(fee >= 0); // dev: invalid fee
        address nTokenAddress = nTokenHandler.nTokenAddress(currencyId);
        (int256 cashBalance, /* */, /* */, /* */) = getBalanceStorage(nTokenAddress, currencyId);
        cashBalance = cashBalance.add(fee);
        setBalanceStorageForNToken(nTokenAddress, currencyId, cashBalance);
    }

    /// @notice increments fees to the reserve
    function incrementFeeToReserve(uint256 currencyId, int256 fee) internal {
        require(fee >= 0); // dev: invalid fee
        // prettier-ignore
        (int256 totalReserve, /* */, /* */, /* */) = getBalanceStorage(Constants.RESERVE, currencyId);
        totalReserve = totalReserve.add(fee);
        _setBalanceStorage(Constants.RESERVE, currencyId, totalReserve, 0, 0, 0);
        emit ReserveFeeAccrued(uint16(currencyId), fee);
    }

    /// @notice harvests excess reserve balance
    function harvestExcessReserveBalance(uint16 currencyId, int256 reserve, int256 assetInternalRedeemAmount) internal {
        // parameters are validated by the caller
        reserve = reserve.subNoNeg(assetInternalRedeemAmount);
        _setBalanceStorage(Constants.RESERVE, currencyId, reserve, 0, 0, 0);
        emit ExcessReserveBalanceHarvested(currencyId, assetInternalRedeemAmount);
    }

    /// @notice sets the reserve balance, see TreasuryAction.setReserveCashBalance
    function setReserveCashBalance(uint16 currencyId, int256 newBalance) internal {
        require(newBalance >= 0); // dev: invalid balance
        _setBalanceStorage(Constants.RESERVE, currencyId, newBalance, 0, 0, 0);
        emit ReserveBalanceUpdated(currencyId, newBalance);
    }

    /// @notice Sets internal balance storage.
    function _setBalanceStorage(
        address account,
        uint256 currencyId,
        int256 cashBalance,
        int256 nTokenBalance,
        uint256 lastClaimTime,
        uint256 accountIncentiveDebt
    ) private {
        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage.getBalanceStorage();
        BalanceStorage storage balanceStorage = store[account][currencyId];

        require(cashBalance >= type(int88).min && cashBalance <= type(int88).max); // dev: stored cash balance overflow
        // Allows for 12 quadrillion nToken balance in 1e8 decimals before overflow
        require(nTokenBalance >= 0 && nTokenBalance <= type(uint80).max); // dev: stored nToken balance overflow

        if (lastClaimTime == 0) {
            // In this case the account has migrated and we set the accountIncentiveDebt
            // The maximum NOTE supply is 100_000_000e8 (1e16) which is less than 2^56 (7.2e16) so we should never
            // encounter an overflow for accountIncentiveDebt
            require(accountIncentiveDebt <= type(uint56).max); // dev: account incentive debt overflow
            balanceStorage.accountIncentiveDebt = uint56(accountIncentiveDebt);
        } else {
            // In this case the last claim time has not changed and we do not update the last integral supply
            // (stored in the accountIncentiveDebt position)
            require(lastClaimTime == balanceStorage.lastClaimTime);
        }

        balanceStorage.lastClaimTime = uint32(lastClaimTime);
        balanceStorage.nTokenBalance = uint80(nTokenBalance);
        balanceStorage.cashBalance = int88(cashBalance);
    }

    /// @notice Gets internal balance storage, nTokens are stored alongside cash balances
    function getBalanceStorage(address account, uint256 currencyId)
        internal
        view
        returns (
            int256 cashBalance,
            int256 nTokenBalance,
            uint256 lastClaimTime,
            uint256 accountIncentiveDebt
        )
    {
        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage.getBalanceStorage();
        BalanceStorage storage balanceStorage = store[account][currencyId];

        nTokenBalance = balanceStorage.nTokenBalance;
        lastClaimTime = balanceStorage.lastClaimTime;
        if (lastClaimTime > 0) {
            // NOTE: this is only necessary to support the deprecated integral supply values, which are stored
            // in the accountIncentiveDebt slot
            accountIncentiveDebt = FloatingPoint56.unpackFrom56Bits(balanceStorage.accountIncentiveDebt);
        } else {
            accountIncentiveDebt = balanceStorage.accountIncentiveDebt;
        }
        cashBalance = balanceStorage.cashBalance;
    }

    /// @notice Loads a balance state memory object
    /// @dev Balance state objects occupy a lot of memory slots, so this method allows
    /// us to reuse them if possible
    function loadBalanceState(
        BalanceState memory balanceState,
        address account,
        uint16 currencyId,
        AccountContext memory accountContext
    ) internal view {
        require(0 < currencyId && currencyId <= Constants.MAX_CURRENCIES); // dev: invalid currency id
        balanceState.currencyId = currencyId;

        if (accountContext.isActiveInBalances(currencyId)) {
            (
                balanceState.storedCashBalance,
                balanceState.storedNTokenBalance,
                balanceState.lastClaimTime,
                balanceState.accountIncentiveDebt
            ) = getBalanceStorage(account, currencyId);
        } else {
            balanceState.storedCashBalance = 0;
            balanceState.storedNTokenBalance = 0;
            balanceState.lastClaimTime = 0;
            balanceState.accountIncentiveDebt = 0;
        }

        balanceState.netCashChange = 0;
        balanceState.netAssetTransferInternalPrecision = 0;
        balanceState.netNTokenTransfer = 0;
        balanceState.netNTokenSupplyChange = 0;
    }

    /// @notice Used when manually claiming incentives in nTokenAction. Also sets the balance state
    /// to storage to update the accountIncentiveDebt. lastClaimTime will be set to zero as accounts
    /// are migrated to the new incentive calculation
    function claimIncentivesManual(BalanceState memory balanceState, address account)
        internal
        returns (uint256 incentivesClaimed)
    {
        incentivesClaimed = Incentives.claimIncentives(
            balanceState,
            account,
            balanceState.storedNTokenBalance.toUint()
        );

        _setBalanceStorage(
            account,
            balanceState.currencyId,
            balanceState.storedCashBalance,
            balanceState.storedNTokenBalance,
            balanceState.lastClaimTime,
            balanceState.accountIncentiveDebt
        );
    }
}
