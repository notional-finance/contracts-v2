// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/PerpetualToken.sol";
import "../math/SafeInt256.sol";
import "../storage/BalanceHandler.sol";
import "../storage/AccountContextHandler.sol";
import "./FreeCollateralExternal.sol";

library MintPerpetualTokenAction {
    using SafeInt256 for int256;
    using BalanceHandler for BalanceState;
    using AccountContextHandler for AccountStorage;

    function perpetualTokenMint(
        uint16 currencyId,
        uint88 amountToDepositExternalPrecision,
        bool useCashBalance
    ) external returns (uint) {
        address recipient = msg.sender;
        AccountStorage memory recipientContext = AccountContextHandler.getAccountContext(recipient);
        BalanceState memory recipientBalance = BalanceHandler.buildBalanceState(
            recipient,
            currencyId,
            recipientContext
        );

        (int amountToDepositInternal, /* int assetAmountTransferred */) = recipientBalance.depositAssetToken(
            recipient,
            int(amountToDepositExternalPrecision),
            useCashBalance
        );
        // Net off any asset amount transferred because it will go to the perp token
        recipientBalance.netCashChange = recipientBalance.netCashChange.sub(amountToDepositInternal);

        int tokensMinted = _mintPerpetualToken(currencyId, amountToDepositInternal);
        recipientBalance.netPerpetualTokenSupplyChange = tokensMinted;
        recipientBalance.finalize(recipient, recipientContext, false);
        recipientContext.setAccountContext(recipient);

        if (recipientContext.hasDebt) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(recipient);
        }

        return uint(tokensMinted);
    }
 
    /**
     * @notice Converts the given amount of cash to perpetual tokens in the same currency. This method can
     * only be called by the contract itself.
     */
    function perpetualTokenMintViaBatch(
        uint currencyId,
        int amountToDepositInternal
    ) external returns (int) {
        require(msg.sender == address(this), "Unauthorized caller");
        return _mintPerpetualToken(currencyId, amountToDepositInternal);
    }

    function _mintPerpetualToken(
        uint currencyId,
        int amountToDepositInternal
    ) private returns (int) {
        uint blockTime = block.timestamp;
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioStateful(currencyId);
        AccountStorage memory perpTokenContext = AccountContextHandler.getAccountContext(perpToken.tokenAddress);

        int tokensMinted = PerpetualToken.mintPerpetualToken(
            perpToken,
            perpTokenContext,
            amountToDepositInternal,
            blockTime
        );
        require(tokensMinted >= 0, "Invalid token amount");

        return tokensMinted;
    }
}
