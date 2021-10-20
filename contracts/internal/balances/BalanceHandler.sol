// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;
pragma abicoder v2;

import "./Incentives.sol";
import "./TokenHandler.sol";
import "../AccountContextHandler.sol";
import "../../global/Types.sol";
import "../../global/Constants.sol";
import "../../math/SafeInt256.sol";
import "../../math/FloatingPoint56.sol";

library BalanceHandler {
    using UserDefinedType for IA;
    using UserDefinedType for NT;
    using UserDefinedType for IU;
    using SafeInt256 for int256;
    using TokenHandler for Token;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountContext;

    /// @notice Emitted when a cash balance changes
    event CashBalanceChange(address indexed account, uint16 indexed currencyId, IA netCashChange);
    /// @notice Emitted when nToken supply changes (not the same as transfers)
    event nTokenSupplyChange(address indexed account, uint16 indexed currencyId, NT tokenSupplyChange);
    /// @notice Emitted when reserve fees are accrued
    event ReserveFeeAccrued(uint16 indexed currencyId, IA fee);

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
    ) internal returns (IA) {
        if (assetAmountExternal == 0) return IA.wrap(0);
        require(assetAmountExternal > 0); // dev: deposit asset token amount negative
        Token memory token = TokenHandler.getAssetToken(balanceState.currencyId);
        IA assetAmountInternal = IA.wrap(token.convertToInternal(assetAmountExternal));

        // Force transfer is used to complete the transfer before going to finalize
        if (token.hasTransferFee || forceTransfer) {
            // If the token has a transfer fee the deposit amount may not equal the actual amount
            // that the contract will receive. We handle the deposit here and then update the netCashChange
            // accordingly which is denominated in internal precision.
            int256 assetAmountExternalPrecisionFinal = token.transfer(account, assetAmountExternal);
            // Convert the external precision to internal, it's possible that we lose dust amounts here but
            // this is unavoidable because we do not know how transfer fees are calculated.
            assetAmountInternal = IA.wrap(token.convertToInternal(assetAmountExternalPrecisionFinal));
            // Transfer has been called
            balanceState.netCashChange = balanceState.netCashChange.add(assetAmountInternal);

            return assetAmountInternal;
        } else {
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
    ) internal returns (IA) {
        if (underlyingAmountExternal == 0) return IA.wrap(0);
        require(underlyingAmountExternal > 0); // dev: deposit underlying token negative

        Token memory underlyingToken = TokenHandler.getUnderlyingToken(balanceState.currencyId);
        // This is the exact amount of underlying tokens the account has in external precision.
        if (underlyingToken.tokenType == TokenType.Ether) {
            // Underflow checked above
            require(uint256(underlyingAmountExternal) == msg.value, "ETH Balance");
        } else {
            underlyingAmountExternal = underlyingToken.transfer(account, underlyingAmountExternal);
        }

        Token memory assetToken = TokenHandler.getAssetToken(balanceState.currencyId);
        // Tokens that are not mintable like cTokens will be deposited as assetTokens
        require(assetToken.tokenType == TokenType.cToken || assetToken.tokenType == TokenType.cETH); // dev: deposit underlying token invalid token type
        int256 assetTokensReceivedExternalPrecision =
            assetToken.mint(SafeInt256.toUint(underlyingAmountExternal));

        // cTokens match INTERNAL_TOKEN_PRECISION so this will short circuit but we leave this here in case a different
        // type of asset token is listed in the future. It's possible if those tokens have a different precision dust may
        // accrue but that is not relevant now.
        IA assetTokensReceivedInternal =
            IA.wrap(assetToken.convertToInternal(assetTokensReceivedExternalPrecision));
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
        if (balanceState.netNTokenTransfer.isNegNotZero()) {
            require(
                balanceState.storedNTokenBalance
                    .add(balanceState.netNTokenSupplyChange)
                    .add(balanceState.netNTokenTransfer).isPosOrZero(),
                "Neg nToken"
            );
        }

        if (balanceState.netAssetTransferInternalPrecision.isNegNotZero()) {
            require(
                balanceState.storedCashBalance
                    .add(balanceState.netCashChange)
                    .add(balanceState.netAssetTransferInternalPrecision).isPosOrZero(),
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
        IA totalCashChange = balanceState.netCashChange.add(balanceState.netAssetTransferInternalPrecision);

        if (totalCashChange.isNotZero()) {
            balanceState.storedCashBalance = balanceState.storedCashBalance.add(totalCashChange);
            mustUpdate = true;

            emit CashBalanceChange(
                account,
                uint16(balanceState.currencyId),
                totalCashChange
            );
        }

        if (balanceState.netNTokenTransfer.isNotZero() || balanceState.netNTokenSupplyChange.isNotZero()) {
            // It's crucial that incentives are claimed before we do any sort of nToken transfer to prevent gaming
            // of the system. This method will update the lastClaimTime time and lastIntegralTotalSupply in balance
            // state in place.
            Incentives.claimIncentives(balanceState, account);

            // nTokens are within the notional system so we can update balances directly.
            balanceState.storedNTokenBalance = balanceState
                .storedNTokenBalance
                .add(balanceState.netNTokenTransfer)
                .add(balanceState.netNTokenSupplyChange);

            if (balanceState.netNTokenSupplyChange.isNotZero()) {
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
                balanceState.lastClaimIntegralSupply
            );
        }

        accountContext.setActiveCurrency(
            balanceState.currencyId,
            // Set active currency to true if either balance is non-zero
            balanceState.storedCashBalance.isNotZero() || balanceState.storedNTokenBalance.isNotZero(),
            Constants.ACTIVE_IN_BALANCES
        );

        if (balanceState.storedCashBalance.isNegNotZero()) {
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
    ) private returns (int256 actualTransferAmountExternal, IA assetTransferAmountInternal) {
        Token memory assetToken = TokenHandler.getAssetToken(balanceState.currencyId);
        // Dust accrual to the protocol is possible if the token decimals is less than internal token precision.
        // See the comments in TokenHandler.convertToExternal and TokenHandler.convertToInternal
        int256 assetTransferAmountExternal =
            assetToken.convertToExternal(IA.unwrap(balanceState.netAssetTransferInternalPrecision));

        if (assetTransferAmountExternal == 0) {
            return (0, IA.wrap(0));
        } else if (redeemToUnderlying && assetTransferAmountExternal < 0) {
            // We only do the redeem to underlying if the asset transfer amount is less than zero. If it is greater than
            // zero then we will do a normal transfer instead.

            // We use the internal amount here and then scale it to the external amount so that there is
            // no loss of precision between our internal accounting and the external account. In this case
            // there will be no dust accrual in underlying tokens since we will transfer the exact amount
            // of underlying that was received.
            Token memory underlyingToken = TokenHandler.getUnderlyingToken(balanceState.currencyId);
            // underlyingAmountExternal is converted from uint to int inside redeem, must be positive
            int256 underlyingAmountExternal = assetToken.redeem(
                underlyingToken,
                uint256(assetTransferAmountExternal.neg())
            );

            // Withdraws the underlying amount out to the destination account
            actualTransferAmountExternal = underlyingToken.transfer(
                account,
                underlyingAmountExternal.neg()
            );
            // In this case we're transferring underlying tokens, we want to convert the internal
            // asset transfer amount to store in cash balances
            assetTransferAmountInternal = IA.wrap(assetToken.convertToInternal(assetTransferAmountExternal));
        } else {
            actualTransferAmountExternal = assetToken.transfer(account, assetTransferAmountExternal);
            // Convert the actual transferred amount
            assetTransferAmountInternal = IA.wrap(assetToken.convertToInternal(actualTransferAmountExternal));
        }
    }

    /// @notice Special method for settling negative current cash debts. This occurs when an account
    /// has a negative fCash balance settle to cash. A settler may come and force the account to borrow
    /// at the prevailing 3 month rate
    /// @dev Use this method to avoid any nToken and transfer logic in finalize which is unnecessary.
    function setBalanceStorageForSettleCashDebt(
        address account,
        CashGroupParameters memory cashGroup,
        IA amountToSettleAsset,
        AccountContext memory accountContext
    ) internal returns (IA) {
        require(amountToSettleAsset.isPosOrZero()); // dev: amount to settle negative
        (IA cashBalance, NT nTokenBalance, uint256 lastClaimTime, uint256 lastClaimIntegralSupply) =
            getBalanceStorage(account, cashGroup.currencyId);

        // Prevents settlement of positive balances
        require(cashBalance.isNegNotZero(), "Invalid settle balance");
        if (amountToSettleAsset.isZero()) {
            // Symbolizes that the entire debt should be settled
            amountToSettleAsset = cashBalance.neg();
            cashBalance = IA.wrap(0);
        } else {
            // A partial settlement of the debt
            require(amountToSettleAsset.lte(cashBalance.neg()), "Invalid amount to settle");
            cashBalance = cashBalance.add(amountToSettleAsset);
        }

        // NOTE: we do not update HAS_CASH_DEBT here because it is possible that the other balances
        // also have cash debts
        if (cashBalance.isZero() && nTokenBalance.isZero()) {
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
            lastClaimIntegralSupply
        );

        // Emit the event here, we do not call finalize
        emit CashBalanceChange(account, cashGroup.currencyId, amountToSettleAsset);

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
            if (amt.netCashChange.isZero()) continue;

            (
                IA cashBalance,
                NT nTokenBalance,
                uint256 lastClaimTime,
                uint256 lastClaimIntegralSupply
            ) = getBalanceStorage(account, amt.currencyId);

            cashBalance = cashBalance.add(amt.netCashChange);
            accountContext.setActiveCurrency(
                amt.currencyId,
                cashBalance.isNotZero() || nTokenBalance.isNotZero(),
                Constants.ACTIVE_IN_BALANCES
            );

            if (cashBalance.isNegNotZero()) {
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
                lastClaimIntegralSupply
            );
        }
    }

    /// @notice Special method for setting balance storage for nToken
    function setBalanceStorageForNToken(
        address nTokenAddress,
        uint256 currencyId,
        IA cashBalance
    ) internal {
        require(cashBalance.isPosOrZero()); // dev: invalid nToken cash balance
        _setBalanceStorage(nTokenAddress, currencyId, cashBalance, NT.wrap(0), 0, 0);
    }

    /// @notice increments fees to the reserve
    function incrementFeeToReserve(uint256 currencyId, IA fee) internal {
        require(IA.unwrap(fee) >= 0); // dev: invalid fee
        // prettier-ignore
        (IA totalReserve, /* */, /* */, /* */) = getBalanceStorage(Constants.RESERVE, currencyId);
        totalReserve = totalReserve.add(fee);
        _setBalanceStorage(Constants.RESERVE, currencyId, totalReserve, NT.wrap(0), 0, 0);
        emit ReserveFeeAccrued(uint16(currencyId), fee);
    }

    /// @notice Sets internal balance storage.
    function _setBalanceStorage(
        address account,
        uint256 currencyId,
        IA cashBalance,
        NT nTokenBalance,
        uint256 lastClaimTime,
        uint256 lastClaimIntegralSupply
    ) private {
        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage.getBalanceStorage();
        BalanceStorage storage balanceStorage = store[account][currencyId];

        // Allows for 12 quadrillion nToken balance in 1e8 decimals before overflow
        require(lastClaimTime <= type(uint32).max); // dev: last claim time overflow

        balanceStorage.nTokenBalance = nTokenBalance.toStorage();
        balanceStorage.lastClaimTime = uint32(lastClaimTime);
        balanceStorage.cashBalance = cashBalance.toBalanceStorage();

        // Last claim supply is stored in a "floating point" storage slot that does not maintain exact precision but
        // is also not limited by storage overflows. `packTo56Bits` will ensure that the the returned value will fit
        // in 56 bits (7 bytes)
        balanceStorage.packedLastClaimIntegralSupply = FloatingPoint56.packTo56Bits(lastClaimIntegralSupply);
    }

    /// @notice Gets internal balance storage, nTokens are stored alongside cash balances
    function getBalanceStorage(address account, uint256 currencyId)
        internal
        view
        returns (
            IA cashBalance,
            NT nTokenBalance,
            uint256 lastClaimTime,
            uint256 lastClaimIntegralSupply
        )
    {
        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage.getBalanceStorage();
        BalanceStorage storage balanceStorage = store[account][currencyId];

        nTokenBalance = NT.wrap(int256(uint256(balanceStorage.nTokenBalance)));
        lastClaimTime = balanceStorage.lastClaimTime;
        lastClaimIntegralSupply = FloatingPoint56.unpackFrom56Bits(balanceStorage.packedLastClaimIntegralSupply);
        cashBalance = IA.wrap(balanceStorage.cashBalance);
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
                balanceState.lastClaimIntegralSupply
            ) = getBalanceStorage(account, currencyId);
        } else {
            balanceState.storedCashBalance = IA.wrap(0);
            balanceState.storedNTokenBalance = NT.wrap(0);
            balanceState.lastClaimTime = 0;
            balanceState.lastClaimIntegralSupply = 0;
        }

        balanceState.netCashChange = IA.wrap(0);
        balanceState.netAssetTransferInternalPrecision = IA.wrap(0);
        balanceState.netNTokenTransfer = NT.wrap(0);
        balanceState.netNTokenSupplyChange = NT.wrap(0);
    }

    /// @notice Used when manually claiming incentives in nTokenAction. Also sets the balance state
    /// to storage to update the lastClaimTime and lastClaimIntegralSupply
    function claimIncentivesManual(BalanceState memory balanceState, address account)
        internal
        returns (uint256)
    {
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
