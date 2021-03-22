// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./SettleAssets.sol";
import "./StorageLayoutV1.sol";
import "./TokenHandler.sol";
import "./AccountContextHandler.sol";
import "../common/PerpetualToken.sol";
import "../math/Bitmap.sol";
import "../math/SafeInt256.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

struct BalanceState {
    uint currencyId;
    // Cash balance stored in balance state at the beginning of the transaction
    int storedCashBalance;
    // Perpetual token balance stored at the beginning of the transaction
    int storedPerpetualTokenBalance;
    // The net cash change as a result of asset settlement or trading
    int netCashChange;
    // Net asset transfers into or out of the account
    int netAssetTransferInternalPrecision;
    // Net perpetual token transfers into or out of the account
    int netPerpetualTokenTransfer;
    // Net perpetual token supply change from minting or redeeming
    int netPerpetualTokenSupplyChange;
    // The last time incentives were minted for this currency id
    uint lastIncentiveMint;
}

library BalanceHandler {
    using SafeInt256 for int;
    using SafeMath for uint;
    using Bitmap for bytes;
    using TokenHandler for Token;
    using AccountContextHandler for AccountStorage;

    /**
     * @notice Handles two special cases when depositing tokens into an account.
     *  - If a token has transfer fees then the amount specified does not equal the amount that the contract
     *    will receive. Complete the deposit here rather than in finalize so that the contract has the correct
     *    balance to work with.
     *  - A method may specify that it wants to apply positive cash balances against the deposit, netting off the
     *    amount that must actually be transferred. In this case we use the cash balance to determine the net amount
     *    required to deposit
     * @return Returns two values:
     *  - assetAmountInternal which is the converted asset amount accounting for transfer fees
     *  - assetAmountTransferred which is the internal precision amount transferred into the account
     */
    function depositAssetToken(
        BalanceState memory balanceState,
        address account,
        int assetAmountExternalPrecision,
        bool useCashBalance
    ) internal returns (int, int) {
        if (assetAmountExternalPrecision == 0) return (0, 0);
        require(assetAmountExternalPrecision > 0); // dev: deposit asset token amount negative
        Token memory token = TokenHandler.getToken(balanceState.currencyId, false);
        int assetAmountInternal = token.convertToInternal(assetAmountExternalPrecision);
        int assetAmountTransferred;

        if (useCashBalance) {
            // Calculate what we assume the total cash position to be if transfers and cash changes are
            // successful. We then apply any positive amount of this total cash balance to net off the deposit.
            int totalCash = balanceState.storedCashBalance
                .add(balanceState.netCashChange)
                .add(balanceState.netAssetTransferInternalPrecision);

            if (totalCash > assetAmountInternal) {
                // Sufficient total cash to account for the deposit so no transfer is necessary
                return (assetAmountInternal, 0);
            } else if (totalCash > 0) {
                // Set the remainder as the transfer amount
                assetAmountExternalPrecision = token.convertToExternal(assetAmountInternal.sub(totalCash));
            }
        }

        if (token.hasTransferFee) {
            // If the token has a transfer fee the deposit amount may not equal the actual amount
            // that the contract will receive. We handle the deposit here and then update the netCashChange
            // accordingly which is denominated in internal precision.
            int assetAmountExternalPrecisionFinal = token.transfer(account, assetAmountExternalPrecision);
            // Convert the external precision to internal, it's possible that we lose dust amounts here but
            // this is unavoidable because we do not know how transfer fees are calculated.
            assetAmountTransferred = token.convertToInternal(assetAmountExternalPrecisionFinal);
            balanceState.netCashChange = balanceState.netCashChange.add(assetAmountTransferred);

            // This is the total amount change accounting for the transfer fee.
            assetAmountInternal = assetAmountInternal.sub(
                token.convertToInternal(assetAmountExternalPrecision.sub(assetAmountExternalPrecisionFinal))
            );

            return (assetAmountInternal, assetAmountTransferred);
        }

        // Otherwise add the asset amount here. It may be net off later and we want to only do
        // a single transfer during the finalize method. Use internal precision to ensure that internal accounting
        // and external account remain in sync.
        assetAmountTransferred = token.convertToInternal(assetAmountExternalPrecision);
        balanceState.netAssetTransferInternalPrecision = balanceState.netAssetTransferInternalPrecision
            .add(assetAmountTransferred);

        // Returns the converted assetAmountExternalPrecision to the internal amount
        return (assetAmountInternal, assetAmountTransferred);
    }

    /**
     * @notice If the user specifies and underlying token amount to deposit then we will need to transfer the
     * underlying and then wrap it into the asset token. In any case, to get the exact amount of asset tokens the
     * contract will receive we must transfer and wrap immediately, it is not possible to precisely net off underlying
     * transfers because they will change the composition of the asset token.
     */
    function depositUnderlyingToken(
        BalanceState memory balanceState,
        address account,
        int underlyingAmountExternalPrecision
    ) internal returns (int) {
        if (underlyingAmountExternalPrecision == 0) return 0;
        require(underlyingAmountExternalPrecision > 0); // dev: deposit underlying token nevative
        
        Token memory underlyingToken = TokenHandler.getToken(balanceState.currencyId, true);
        // This is the exact amount of underlying tokens the account has in external precision.
        underlyingAmountExternalPrecision = underlyingToken.transfer(account, underlyingAmountExternalPrecision);

        Token memory assetToken = TokenHandler.getToken(balanceState.currencyId, false);
        require(assetToken.tokenType == TokenType.cToken); // dev: deposit underlying token invalid token type
        int assetTokensReceivedExternalPrecision = assetToken.mint(uint(underlyingAmountExternalPrecision));

        // Some dust may be lost here due to internal conversion, however, for cTokens this will not be an issue
        // since internally we use 9 decimal precision versus 8 for cTokens. Dust accural here is unavoidable due
        // to the fact that we do not know how asset tokens will be minted.
        int assetTokensReceivedInternal = assetToken.convertToInternal(assetTokensReceivedExternalPrecision);
        balanceState.netCashChange = balanceState.netCashChange.add(assetTokensReceivedInternal);

        return assetTokensReceivedInternal;
    }

    /**
     * @notice Call this in order to transfer cash in and out of the Notional system as well as update
     * internal cash balances.
     *
     * @dev This method SHOULD NOT be used for perpetual token accounts, for that use setBalanceStorageForPerpToken
     * as the perp token is limited in what types of balances it can hold.
     */
    function finalize(
        BalanceState memory balanceState,
        address account,
        AccountStorage memory accountContext,
        bool redeemToUnderlying
    ) internal returns (int) {
        bool mustUpdate;
        int transferAmountExternal;
        if (balanceState.netPerpetualTokenTransfer < 0) {
            require(
                balanceState.storedPerpetualTokenBalance
                    .add(balanceState.netPerpetualTokenSupplyChange) >= balanceState.netPerpetualTokenTransfer.neg(),
                "BH: cannot withdraw negative"
            );
        }

        if (balanceState.netAssetTransferInternalPrecision < 0) {
            require(
                balanceState.storedCashBalance
                    .add(balanceState.netCashChange)
                    .add(balanceState.netAssetTransferInternalPrecision) >= 0,
                "BH: cannot withdraw negative"
            );
        }

        if (balanceState.netAssetTransferInternalPrecision != 0) {
            Token memory assetToken = TokenHandler.getToken(balanceState.currencyId, false);
            transferAmountExternal = assetToken.convertToExternal(balanceState.netAssetTransferInternalPrecision);

            if (redeemToUnderlying) {
                // We use the internal amount here and then scale it to the external amount so that there is
                // no loss of precision between our internal accounting and the external account. In this case
                // there will be no dust accrual since we will transfer the exact amount of underlying that was
                // received.
                require(transferAmountExternal < 0, "BH: cannot redeem negative");
                Token memory underlyingToken = TokenHandler.getToken(balanceState.currencyId, true);
                int underlyingAmountExternalPrecision = assetToken.redeem(
                    underlyingToken,
                    // TODO: dust may accrue at the lowest decimal place
                    uint(transferAmountExternal.neg())
                );

                // Withdraws the underlying amount out to the destination account
                underlyingToken.transfer(account, underlyingAmountExternalPrecision.neg());
            } else {
                transferAmountExternal = assetToken.transfer(account, transferAmountExternal);
            }

            // Convert the actual transferred amount 
            balanceState.netAssetTransferInternalPrecision = assetToken.convertToInternal(transferAmountExternal);
        }

        balanceState.storedCashBalance = balanceState.storedCashBalance
            .add(balanceState.netCashChange)
            // Transfer fees will always reduce netAssetTransfer so the receiving account will receive less
            // but the Notional system will account for the total net transfer here.
            .add(balanceState.netAssetTransferInternalPrecision);
        mustUpdate = balanceState.netCashChange != 0 || balanceState.netAssetTransferInternalPrecision != 0;

        if (balanceState.netPerpetualTokenTransfer != 0 || balanceState.netPerpetualTokenSupplyChange != 0) {
            // It's crucial that this is minted before we do any sort of perpetual token transfer to prevent gaming
            // of the system. This method will update the lastIncentiveMint time in the balanceState for storage.
            mintIncentives(balanceState, account);

            // Perpetual tokens are within the notional system so we can update balances directly.
            balanceState.storedPerpetualTokenBalance = balanceState.storedPerpetualTokenBalance
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
                balanceState.lastIncentiveMint
            );
        }

        accountContext.setActiveCurrency(
            balanceState.currencyId,
            // Set active currency to true if either balance is non-zero
            balanceState.storedCashBalance != 0 || balanceState.storedPerpetualTokenBalance != 0
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
        uint currencyId,
        int amountToSettle
    ) internal returns (int) {
        require(amountToSettle >= 0); // dev: amount to settle negative
        (int cashBalance, int perpetualTokenBalance, uint lastIncentiveMint) = getBalanceStorage(account, currencyId);

        require(cashBalance < 0, "Invalid settle balance");
        if (amountToSettle == 0) {
            amountToSettle = cashBalance.neg();
            cashBalance = 0;
        } else {
            require(amountToSettle <= cashBalance.neg(), "Invalid amount to settle");
            cashBalance = cashBalance.add(amountToSettle);
        }

        setBalanceStorage(account, currencyId, cashBalance, perpetualTokenBalance, lastIncentiveMint);
        return amountToSettle;
    }

    function finalizeSettleAmounts(
        address account,
        AccountStorage memory accountContext,
        SettleAmount[] memory settleAmounts
    ) internal {
        for (uint i; i < settleAmounts.length; i++) {
            if (settleAmounts[i].netCashChange == 0) continue;
            (
                int cashBalance,
                int perpetualTokenBalance,
                uint lastIncentiveMint
            ) = getBalanceStorage(account, settleAmounts[i].currencyId);

            cashBalance = cashBalance.add(settleAmounts[i].netCashChange);
            accountContext.setActiveCurrency(
                settleAmounts[i].currencyId,
                cashBalance != 0 || perpetualTokenBalance != 0
            );

            if (cashBalance < 0) {
                accountContext.hasDebt = accountContext.hasDebt | AccountContextHandler.HAS_CASH_DEBT;
            }
            setBalanceStorage(account, settleAmounts[i].currencyId, cashBalance,
                perpetualTokenBalance, lastIncentiveMint);
        }
    }


    /**
     * @notice Special method for setting balance storage for perp token, during initialize
     * markets to reduce code size.
     */
    function setBalanceStorageForPerpToken(
        PerpetualTokenPortfolio memory perpToken
    ) internal {
        require(perpToken.cashBalance >= 0); // dev: invalid perp token cash balance
        setBalanceStorage(
            perpToken.tokenAddress,
            perpToken.cashGroup.currencyId,
            perpToken.cashBalance, 0, 0
        );
    }

    /**
     * @notice Sets internal balance storage.
     */
    function setBalanceStorage(
        address account,
        uint currencyId,
        int cashBalance,
        int perpetualTokenBalance,
        uint lastIncentiveMint
    ) private {
        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));

        require(
            cashBalance >= type(int128).min && cashBalance <= type(int128).max
        ); // dev: stored cash balance overflow

        require(
            perpetualTokenBalance >= 0 && perpetualTokenBalance <= type(uint96).max
        ); // dev: stored perpetual token balance overflow

        require(
            lastIncentiveMint >= 0 && lastIncentiveMint <= type(uint32).max
        ); // dev: last incentive mint overflow

        bytes32 data = (
            (bytes32(uint(perpetualTokenBalance))) |
            (bytes32(lastIncentiveMint) << 96) |
            (bytes32(cashBalance) << 128)
        );

        assembly { sstore(slot, data) }
    }

    /**
     * @notice Gets internal balance storage, perpetual tokens are stored alongside cash balances
     */
    function getBalanceStorage(address account, uint currencyId) internal view returns (int, int, uint) {
        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        return (
            int(int128(int(data >> 128))),       // Cash balance
            int(uint96(uint(data))),             // Perpetual token balance
            uint(uint32(uint(data >> 96)))       // Last incentive mint blocktime
        );
    }

    function loadBalanceState(
        BalanceState memory balanceState,
        address account,
        uint currencyId,
        AccountStorage memory accountContext
    ) internal view {
        require(currencyId != 0, "BH: invalid currency id");
        balanceState.currencyId = currencyId;

        if (accountContext.isActiveCurrency(currencyId)) {
            (
                balanceState.storedCashBalance,
                balanceState.storedPerpetualTokenBalance,
                balanceState.lastIncentiveMint
            ) = getBalanceStorage(account, currencyId);
        } else {
            balanceState.storedCashBalance = 0;
            balanceState.storedPerpetualTokenBalance = 0;
            balanceState.lastIncentiveMint = 0;
        }

        balanceState.netCashChange = 0;
        balanceState.netAssetTransferInternalPrecision = 0;
        balanceState.netPerpetualTokenTransfer = 0;
        balanceState.netPerpetualTokenSupplyChange = 0;
    }

    /**
     * @notice Builds a currency state object, assumes a valid currency id
     */
    function buildBalanceState(
        address account,
        uint currencyId,
        AccountStorage memory accountContext
    ) internal view returns (BalanceState memory) {
        require(currencyId != 0, "BH: invalid currency id");
        BalanceState memory balanceState;
        balanceState.currencyId = currencyId;

        if (accountContext.isActiveCurrency(currencyId)) {
            // Storage Read
            (
                balanceState.storedCashBalance,
                balanceState.storedPerpetualTokenBalance,
                balanceState.lastIncentiveMint
            ) = getBalanceStorage(account, currencyId);
        }

        return balanceState;
    }

    function buildBalanceStateArray(
        address account,
        uint16[] calldata currencyIds,
        AccountStorage memory accountContext
    ) internal view returns (BalanceState[] memory) {
        BalanceState[] memory balanceStates = new BalanceState[](currencyIds.length);

        for (uint i; i < currencyIds.length; i++) {
            require(currencyIds[i] != 0, "BH: invalid currency id");
            // TODO: how do we know that the currency id is valid?
            if (i > 0) require(currencyIds[i] > currencyIds[i - 1], "BH: Unordered currency ids");

            if (accountContext.isActiveCurrency(currencyIds[i])) {
                (
                    balanceStates[i].storedCashBalance,
                    balanceStates[i].storedPerpetualTokenBalance,
                    balanceStates[i].lastIncentiveMint
                ) = getBalanceStorage(account, currencyIds[i]);
            }
        }

        return balanceStates;
    }

    /**
     * @notice Iterates over an array of balances and returns the total incentives to mint.
     */
    function calculateIncentivesToMint(
        address tokenAddress,
        uint perpetualTokenBalance,
        uint lastMintTime,
        uint blockTime
    ) internal view returns (uint) {
        if (lastMintTime == 0 || lastMintTime >= blockTime) return 0;

        (
            /* currencyId */,
            uint totalSupply,
            uint incentiveAnnualEmissionRate,
            /* arrayLength */,
            /* initializedTime */
        ) = PerpetualToken.getPerpetualTokenContext(tokenAddress);

        uint timeSinceLastMint = blockTime - lastMintTime;
        // perpetualTokenBalance, totalSupply incentives are all in INTERNAL_TOKEN_PRECISION
        // timeSinceLastMint and CashGroup.YEAR are both in seconds
        // incentiveAnnualEmissionRate is an annualized rate in Market.RATE_PRECISION
        // tokenPrecision * seconds * ratePrecision / (seconds * ratePrecision * tokenPrecision)
        uint incentivesToMint = perpetualTokenBalance
            .mul(timeSinceLastMint)
            .mul(uint(TokenHandler.INTERNAL_TOKEN_PRECISION))
            .mul(incentiveAnnualEmissionRate);

        incentivesToMint = incentivesToMint
            .div(CashGroup.YEAR)
            .div(uint(Market.RATE_PRECISION))
            .div(totalSupply);

        return incentivesToMint;
    }

    /**
     * @notice Incentives must be minted every time perpetual token balance changes
     */
    function mintIncentives(
        BalanceState memory balanceState,
        address account
    ) internal {
        uint blockTime = block.timestamp;
        address tokenAddress = PerpetualToken.getPerpetualTokenAddress(balanceState.currencyId);

        uint incentivesToMint = calculateIncentivesToMint(
            tokenAddress,
            uint(balanceState.storedPerpetualTokenBalance),
            balanceState.lastIncentiveMint,
            blockTime
        );
        balanceState.lastIncentiveMint = blockTime;
        if (incentivesToMint > 0) TokenHandler.transferIncentive(account, incentivesToMint);

        // Change the supply amount after incentives have been minted
        if (balanceState.netPerpetualTokenSupplyChange != 0) {
            PerpetualToken.changePerpetualTokenSupply(tokenAddress, balanceState.netPerpetualTokenSupplyChange);
        }
    }

}
