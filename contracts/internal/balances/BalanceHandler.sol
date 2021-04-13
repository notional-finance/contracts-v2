// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./Incentives.sol";
import "./TokenHandler.sol";
import "../AccountContextHandler.sol";
import "../markets/AssetRate.sol";
import "../../global/Types.sol";
import "../../global/Constants.sol";
import "../../math/SafeInt256.sol";

library BalanceHandler {
    using SafeInt256 for int256;
    using TokenHandler for Token;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountStorage;

    /// @notice Handles two special cases when depositing tokens into an account.
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
        int256 assetAmountExternalPrecision,
        bool useCashBalance
    ) internal returns (int256, int256) {
        if (assetAmountExternalPrecision == 0) return (0, 0);
        require(assetAmountExternalPrecision > 0); // dev: deposit asset token amount negative
        Token memory token = TokenHandler.getToken(balanceState.currencyId, false);
        int256 assetAmountInternal = token.convertToInternal(assetAmountExternalPrecision);
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
                assetAmountExternalPrecision = token.convertToExternal(
                    assetAmountInternal.sub(totalCash)
                );
            }
        }

        if (token.hasTransferFee) {
            // If the token has a transfer fee the deposit amount may not equal the actual amount
            // that the contract will receive. We handle the deposit here and then update the netCashChange
            // accordingly which is denominated in internal precision.
            int256 assetAmountExternalPrecisionFinal =
                token.transfer(account, assetAmountExternalPrecision);
            // Convert the external precision to internal, it's possible that we lose dust amounts here but
            // this is unavoidable because we do not know how transfer fees are calculated.
            assetAmountTransferred = token.convertToInternal(assetAmountExternalPrecisionFinal);
            balanceState.netCashChange = balanceState.netCashChange.add(assetAmountTransferred);

            // This is the total amount change accounting for the transfer fee.
            assetAmountInternal = assetAmountInternal.sub(
                token.convertToInternal(
                    assetAmountExternalPrecision.sub(assetAmountExternalPrecisionFinal)
                )
            );

            return (assetAmountInternal, assetAmountTransferred);
        }

        // Otherwise add the asset amount here. It may be net off later and we want to only do
        // a single transfer during the finalize method. Use internal precision to ensure that internal accounting
        // and external account remain in sync.
        assetAmountTransferred = token.convertToInternal(assetAmountExternalPrecision);
        balanceState.netAssetTransferInternalPrecision = balanceState
            .netAssetTransferInternalPrecision
            .add(assetAmountTransferred);

        // Returns the converted assetAmountExternalPrecision to the internal amount
        return (assetAmountInternal, assetAmountTransferred);
    }

    /// @notice If the user specifies and underlying token amount to deposit then we will need to transfer the
    /// underlying and then wrap it into the asset token. In any case, to get the exact amount of asset tokens the
    /// contract will receive we must transfer and wrap immediately, it is not possible to precisely net off underlying
    /// transfers because they will change the composition of the asset token.

    function depositUnderlyingToken(
        BalanceState memory balanceState,
        address account,
        int256 underlyingAmountExternalPrecision
    ) internal returns (int256) {
        if (underlyingAmountExternalPrecision == 0) return 0;
        require(underlyingAmountExternalPrecision > 0); // dev: deposit underlying token nevative

        Token memory underlyingToken = TokenHandler.getToken(balanceState.currencyId, true);
        // This is the exact amount of underlying tokens the account has in external precision.
        if (underlyingToken.tokenType == TokenType.Ether) {
            underlyingAmountExternalPrecision = int256(msg.value);
        } else {
            underlyingAmountExternalPrecision = underlyingToken.transfer(
                account,
                underlyingAmountExternalPrecision
            );
        }

        Token memory assetToken = TokenHandler.getToken(balanceState.currencyId, false);
        require(assetToken.tokenType == TokenType.cToken || assetToken.tokenType == TokenType.cETH); // dev: deposit underlying token invalid token type
        int256 assetTokensReceivedExternalPrecision =
            assetToken.mint(uint256(underlyingAmountExternalPrecision));

        // Some dust may be lost here due to internal conversion, however, for cTokens this will not be an issue
        // since internally we use 9 decimal precision versus 8 for cTokens. Dust accural here is unavoidable due
        // to the fact that we do not know how asset tokens will be minted.
        int256 assetTokensReceivedInternal =
            assetToken.convertToInternal(assetTokensReceivedExternalPrecision);
        balanceState.netCashChange = balanceState.netCashChange.add(assetTokensReceivedInternal);

        return assetTokensReceivedInternal;
    }

    /// @notice Call this in order to transfer cash in and out of the Notional system as well as update
    /// internal cash balances.
    /// @dev This method SHOULD NOT be used for perpetual token accounts, for that use setBalanceStorageForPerpToken
    /// as the perp token is limited in what types of balances it can hold.

    function finalize(
        BalanceState memory balanceState,
        address account,
        AccountStorage memory accountContext,
        bool redeemToUnderlying
    ) internal returns (int256) {
        bool mustUpdate;
        int256 transferAmountExternal;
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
                int256 underlyingAmountExternalPrecision =
                    assetToken.redeem(
                        underlyingToken,
                        // TODO: dust may accrue at the lowest decimal place
                        uint256(transferAmountExternal.neg())
                    );

                // Withdraws the underlying amount out to the destination account
                underlyingToken.transfer(account, underlyingAmountExternalPrecision.neg());
            } else {
                transferAmountExternal = assetToken.transfer(account, transferAmountExternal);
            }

            // Convert the actual transferred amount
            balanceState.netAssetTransferInternalPrecision = assetToken.convertToInternal(
                transferAmountExternal
            );
        }

        balanceState.storedCashBalance = balanceState
            .storedCashBalance
            .add(balanceState.netCashChange)
        // Transfer fees will always reduce netAssetTransfer so the receiving account will receive less
        // but the Notional system will account for the total net transfer here.
            .add(balanceState.netAssetTransferInternalPrecision);
        mustUpdate =
            balanceState.netCashChange != 0 ||
            balanceState.netAssetTransferInternalPrecision != 0;

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
            setBalanceStorage(
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
            // NOTE: this cannot be extinguished except by a free collateral check where all balances
            // are examined
            accountContext.hasDebt = accountContext.hasDebt | AccountContextHandler.HAS_CASH_DEBT;
        }

        return transferAmountExternal;
    }

    function setBalanceStorageForSettleCashDebt(
        address account,
        CashGroupParameters memory cashGroup,
        int256 amountToSettle,
        AccountStorage memory accountContext
    ) internal returns (int256, int256) {
        require(amountToSettle >= 0); // dev: amount to settle negative
        (int256 cashBalance, int256 nTokenBalance, uint256 lastIncentiveClaim) =
            getBalanceStorage(account, cashGroup.currencyId);

        require(cashBalance < 0, "Invalid settle balance");
        int256 amountToSettleAsset;
        if (amountToSettle == 0) {
            amountToSettleAsset = cashBalance.neg();
            amountToSettle = cashGroup.assetRate.convertInternalToUnderlying(amountToSettleAsset);
            cashBalance = 0;
        } else {
            amountToSettleAsset = cashGroup.assetRate.convertInternalFromUnderlying(amountToSettle);
            require(amountToSettleAsset <= cashBalance.neg(), "Invalid amount to settle");
            cashBalance = cashBalance.add(amountToSettleAsset);
        }

        if (cashBalance == 0) {
            accountContext.setActiveCurrency(
                cashGroup.currencyId,
                false,
                AccountContextHandler.ACTIVE_IN_BALANCES_FLAG
            );
        }

        setBalanceStorage(
            account,
            cashGroup.currencyId,
            cashBalance,
            nTokenBalance,
            lastIncentiveClaim
        );
        return (amountToSettle, amountToSettleAsset.neg());
    }

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
            setBalanceStorage(
                account,
                settleAmounts[i].currencyId,
                cashBalance,
                nTokenBalance,
                lastIncentiveClaim
            );
        }
    }

    /// @notice Special method for setting balance storage for perp token

    function setBalanceStorageForPerpToken(
        address perpTokenAddress,
        uint256 currencyId,
        int256 cashBalance
    ) internal {
        require(cashBalance >= 0); // dev: invalid perp token cash balance
        setBalanceStorage(perpTokenAddress, currencyId, cashBalance, 0, 0);
    }

    function incrementFeeToReserve(uint256 currencyId, int256 fee) internal {
        require(fee >= 0); // dev: invalid fee
        (
            int256 totalReserve, /* */ /* */
            ,

        ) = getBalanceStorage(Constants.RESERVE, currencyId);
        totalReserve = totalReserve.add(fee);
        setBalanceStorage(Constants.RESERVE, currencyId, totalReserve, 0, 0);
    }

    /// @notice Sets internal balance storage.

    function setBalanceStorage(
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
            int256,
            int256,
            uint256
        )
    {
        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        return (
            int256(int128(int256(data >> 128))), // Cash balance
            int256(uint96(uint256(data))), // Perpetual token balance
            uint256(uint32(uint256(data >> 96))) // Last incentive claimed blocktime
        );
    }

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

    /// @notice Builds a currency state object, assumes a valid currency id

    function buildBalanceState(
        address account,
        uint256 currencyId,
        AccountStorage memory accountContext
    ) internal view returns (BalanceState memory) {
        require(currencyId != 0, "BH: invalid currency id");
        BalanceState memory balanceState;
        balanceState.currencyId = currencyId;

        if (accountContext.isActiveInBalances(currencyId)) {
            // Storage Read
            (
                balanceState.storedCashBalance,
                balanceState.storedPerpetualTokenBalance,
                balanceState.lastIncentiveClaim
            ) = getBalanceStorage(account, currencyId);
        }

        return balanceState;
    }

    /// @notice Used when manually claiming incentives in nTokenAction
    function claimIncentivesManual(BalanceState memory balanceState, address account)
        internal
        returns (uint256)
    {
        uint256 incentivesClaimed = Incentives.claimIncentives(balanceState, account);
        setBalanceStorage(
            account,
            balanceState.currencyId,
            balanceState.storedCashBalance,
            balanceState.storedPerpetualTokenBalance,
            balanceState.lastIncentiveClaim
        );

        return incentivesClaimed;
    }
}
