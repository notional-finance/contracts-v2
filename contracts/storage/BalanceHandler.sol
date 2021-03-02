// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageLayoutV1.sol";
import "./TokenHandler.sol";
import "./AccountContextHandler.sol";
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
}

library BalanceHandler {
    using SafeInt256 for int;
    using SafeMath for uint;
    using Bitmap for bytes;
    using TokenHandler for Token;
    using AccountContextHandler for AccountStorage;

    uint internal constant BALANCE_STORAGE_SLOT = 8;

    /**
     * @notice 
     */
    function getPerpetualTokenAssetValue(
        BalanceState memory balanceState
    ) internal pure returns (int) { return 0; }

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
        require(assetAmountExternalPrecision > 0, "BH: deposit negative");
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
        require(underlyingAmountExternalPrecision > 0, "BH: deposit negative");
        
        Token memory underlyingToken = TokenHandler.getToken(balanceState.currencyId, true);
        // This is the exact amount of underlying tokens the account has in external precision.
        underlyingAmountExternalPrecision = underlyingToken.transfer(account, underlyingAmountExternalPrecision);

        Token memory assetToken = TokenHandler.getToken(balanceState.currencyId, false);
        require(assetToken.tokenType == TokenType.cToken, "BH: invalid underlying");
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
    ) internal {
        bool mustUpdate;
        if (balanceState.netPerpetualTokenTransfer < 0) {
            require(
                balanceState.storedPerpetualTokenBalance >= balanceState.netPerpetualTokenTransfer.neg(),
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
            int transferAmountExternal = assetToken.convertToExternal(balanceState.netAssetTransferInternalPrecision);

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

        if (balanceState.netPerpetualTokenTransfer != 0) {
            // Perpetual tokens are within the notional system so we can update balances directly.
            balanceState.storedPerpetualTokenBalance = balanceState.storedPerpetualTokenBalance.add(
                balanceState.netPerpetualTokenTransfer
            );
            mustUpdate = true;
        }

        if (mustUpdate) setBalanceStorage(account, balanceState);
        accountContext.setActiveCurrency(
            balanceState.currencyId,
            // Set active currency to true if either balance is non-zero
            balanceState.storedCashBalance != 0 || balanceState.storedPerpetualTokenBalance != 0
        );
        if (balanceState.storedCashBalance < 0) accountContext.hasDebt = true;
    }

    /**
     * @notice Special method for setting balance storage for perp token, during initialize
     * markets to reduce code size.
     */
    function setBalanceStorageForPerpToken(
        BalanceState memory balanceState,
        address perpToken
    ) internal {
        // These factors must always be zero for the perpetual token account
        require(balanceState.storedPerpetualTokenBalance == 0);
        balanceState.storedCashBalance = balanceState.storedCashBalance.add(balanceState.netCashChange);

        // Perpetual token can never have a negative cash balance
        require(balanceState.storedCashBalance >= 0);

        setBalanceStorage(perpToken, balanceState);
    }

    /**
     * @notice Sets internal balance storage.
     */
    function setBalanceStorage(
        address account,
        BalanceState memory balanceState
    ) private {
        bytes32 slot = keccak256(abi.encode(balanceState.currencyId, account, "account.balances"));

        require(
            balanceState.storedCashBalance >= type(int128).min
            && balanceState.storedCashBalance <= type(int128).max,
            "CH: cash balance overflow"
        );

        require(
            balanceState.storedPerpetualTokenBalance >= 0
            && balanceState.storedPerpetualTokenBalance <= type(uint128).max,
            "CH: token balance overflow"
        );

        bytes32 data = (
            // Truncate the higher bits of the signed integer when it is negative
            (bytes32(uint(balanceState.storedPerpetualTokenBalance))) |
            (bytes32(balanceState.storedCashBalance) << 128)
        );

        assembly { sstore(slot, data) }
    }

    /**
     * @notice Get the global incentive data for minting incentives
     */
    function getCurrencyIncentiveData(
        uint currencyId
    ) internal view returns (uint) {
        bytes32 slot = keccak256(abi.encode(currencyId, "currency.incentives"));
        bytes32 data;
        assembly { data := sload(slot) }

        // TODO: where do we store this, on the currency group?
        uint tokenEmissionRate = uint(uint32(uint(data)));

        return tokenEmissionRate;
    }

    /**
     * @notice Gets internal balance storage, perpetual tokens are stored alongside cash balances
     */
    function getBalanceStorage(address account, uint currencyId) internal view returns (int, int) {
        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        return (
            int(int128(int(data >> 128))),          // Cash balance
            int(uint128(uint(data)))  // Perpetual token balance
        );
    }

    /**
     * @notice Builds a currency state object, assumes a valid currency id
     */
    function buildBalanceState(
        address account,
        uint currencyId,
        AccountStorage memory accountContext
    ) internal view returns (BalanceState memory) {
        require(currencyId != 0, "CH: invalid currency id");

        if (accountContext.isActiveCurrency(currencyId)) {
            // Storage Read
            (int cashBalance, int tokenBalance) = getBalanceStorage(account, currencyId);
            return BalanceState({
                currencyId: currencyId,
                storedCashBalance: cashBalance,
                storedPerpetualTokenBalance: tokenBalance,
                netCashChange: 0,
                netAssetTransferInternalPrecision: 0,
                netPerpetualTokenTransfer: 0
            });
        }

        // TODO: does this need to set active currency to ensure reads?
        return BalanceState({
            currencyId: currencyId,
            storedCashBalance: 0,
            storedPerpetualTokenBalance: 0,
            netCashChange: 0,
            netAssetTransferInternalPrecision: 0,
            netPerpetualTokenTransfer: 0
        });
    }

    /**
     * @notice Iterates over an array of balances and returns the total incentives to mint.
    function calculateIncentivesToMint(
        BalanceState[] memory balanceState,
        AccountStorage memory accountContext,
        uint blockTime
    ) internal view returns (uint) {
        // We must mint incentives for all currencies at the same time since we set a single timestamp
        // for when the account last minted incentives.
        require(accountContext.activeCurrencies.totalBitsSet() == 0, "B: must mint currencies");
        require(accountContext.lastMintTime != 0, "B: last mint time zero");
        require(accountContext.lastMintTime < blockTime, "B: last mint time overflow");

        uint timeSinceLastMint = blockTime - accountContext.lastMintTime;
        uint tokensToTransfer;
        for (uint i; i < balanceState.length; i++) {
            // Cannot mint incentives if there is a negative capital deposit. Also we explicitly do not include
            // net capital deposit (the current amount to change) because an account may manipulate this amount to
            // increase their capital deposited figure using flash loans.
            if (balanceState[i].storedCapitalDeposit <= 0) continue;

            (uint globalCapitalDeposit, uint tokenEmissionRate) = getCurrencyIncentiveData(balanceState[i].currencyId);
            if (globalCapitalDeposit == 0 || tokenEmissionRate == 0) continue;

            tokensToTransfer = tokensToTransfer.add(
                // We know that this must be positive
                uint(balanceState[i].storedCapitalDeposit)
                    .mul(timeSinceLastMint)
                    .mul(tokenEmissionRate)
                    .div(CashGroup.YEAR)
                    // tokenEmissionRate is denominated in 1e8
                    .div(uint(TokenHandler.INTERNAL_TOKEN_PRECISION))
                    .div(globalCapitalDeposit)
            );
        }

        require(blockTime <= type(uint32).max, "B: block time overflow");
        accountContext.lastMintTime = uint32(blockTime);
        return tokensToTransfer;
    }
     */

    /**
     * @notice Incentives must be minted before we store netCapitalDeposit changes.
    function mintIncentives(
        BalanceState[] memory balanceState,
        AccountStorage memory accountContext,
        address account,
        uint blockTime
    ) internal returns (uint) {
        uint tokensToTransfer = calculateIncentivesToMint(balanceState, accountContext, blockTime);
        TokenHandler.transferIncentive(account, tokensToTransfer);
        return tokensToTransfer;
    }
     */

}
