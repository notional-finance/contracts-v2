// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/PerpetualToken.sol";
import "../math/SafeInt256.sol";
import "../storage/StorageLayoutV1.sol";
import "../storage/BalanceHandler.sol";
import "../storage/TokenHandler.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MintPerpetualTokenAction is StorageLayoutV1, ReentrancyGuard {
    using SafeInt256 for int;
    using BalanceHandler for BalanceState;
    using TokenHandler for Token;

    // function calculatePerpetualTokensToMintUnderlying(
    //     uint16 currencyId,
    //     uint88 underlyingToDepositExternalPrecision
    // ) external view returns (uint) {
    //     uint amountToDepositInternal = AssetRate
    //         .buildAssetRate(currencyId)
    //         .convertExternalFromUnderlying(underlyingToDepositExternalPrecision);

    //     return _calculatePerpetualTokensToMint(currencyId, amountToDepositInternal);
    // }

    function calculatePerpetualTokensToMint(
        uint16 currencyId,
        uint88 amountToDepositExternalPrecision
    ) external view returns (uint) {
        Token memory token = TokenHandler.getToken(currencyId, false);
        int amountToDepositInternal = token.convertToInternal(int(amountToDepositExternalPrecision));

        return _calculatePerpetualTokensToMint(currencyId, amountToDepositInternal);
    }

    // function perpetualTokenMintUnderlying(
    //     uint16 currencyId,
    //     uint88 underlyingToDepositExternalPrecision
    // ) external returns (uint) nonReentrant {
    //     return _mintPerpetualToken(currencyId, msg.sender, int(amountToDeposit), useCashBalance);
    // }

    function perpetualTokenMint(
        uint16 currencyId,
        uint88 amountToDepositExternalPrecision,
        bool useCashBalance
    ) external nonReentrant returns (uint) {
        // TODO: remove this
        AccountStorage memory recipientContext = accountContextMapping[msg.sender];
        BalanceState memory recipientBalance = BalanceHandler.buildBalanceState(
            msg.sender,
            currencyId,
            recipientContext.activeCurrencies
        );

        (int amountToDepositInternal, int assetAmountTransferred) = recipientBalance.depositAssetToken(
            msg.sender,
            int(amountToDepositExternalPrecision),
            useCashBalance
        );
        // Net off any asset amount transferred because it will go to the perp token
        recipientBalance.netCashChange = recipientBalance.netCashChange.sub(assetAmountTransferred);

        return _mintPerpetualToken(currencyId, msg.sender, recipientBalance, amountToDepositInternal);
    }

    function perpetualTokenRedeem(
        uint16 currencyId,
        uint88 tokensToRedeem
    ) external nonReentrant returns (bool) {
        revert("UNIMPLMENTED");
    }

    function _calculatePerpetualTokensToMint(
        uint currencyId,
        int amountToDeposit
    ) internal view returns (uint) {
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolio(currencyId);
        AccountStorage memory accountContext = accountContextMapping[perpToken.tokenAddress];

        (int tokensToMint, /* */) = PerpetualToken.calculateTokensToMint(
            perpToken,
            accountContext,
            amountToDeposit,
            block.timestamp
        );

        return SafeCast.toUint256(tokensToMint);
    }

    function _mintPerpetualToken(
        uint currencyId,
        address recipient,
        BalanceState memory recipientBalance,
        int amountToDeposit
    ) internal returns (uint) {
        uint blockTime = block.timestamp;

        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolio(currencyId);
        AccountStorage memory accountContext = accountContextMapping[perpToken.tokenAddress];

        recipientBalance.netPerpetualTokenTransfer = PerpetualToken.mintPerpetualToken(
            perpToken,
            accountContext,
            amountToDeposit,
            blockTime
        );

        AccountStorage memory recipientContext = accountContextMapping[recipient];
        recipientBalance.finalize(recipient, recipientContext, false);
        accountContextMapping[recipient] = recipientContext;

        // TODO: must free collateral check here
        if (recipientContext.hasDebt) {
            revert("UNIMPLMENTED");
        }

        return SafeCast.toUint256(recipientBalance.netPerpetualTokenTransfer);
    }
}
