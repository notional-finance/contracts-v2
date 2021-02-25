// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/PerpetualToken.sol";
import "../math/SafeInt256.sol";
import "../storage/StorageLayoutV1.sol";
import "../storage/BalanceHandler.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";

contract MintPerpetualTokenAction is StorageLayoutV1 {
    using SafeInt256 for int;
    using BalanceHandler for BalanceState;

    function calculatePerpetualTokensToMint(
        uint16 currencyId,
        uint88 amountToDeposit
    ) external view returns (uint) {
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolio(currencyId);
        AccountStorage memory accountContext = accountContextMapping[perpToken.tokenAddress];

        (int tokensToMint, /* */) = PerpetualToken.calculateTokensToMint(
            perpToken,
            accountContext,
            int(amountToDeposit),
            block.timestamp
        );

        return SafeCast.toUint256(tokensToMint);
    }

    function perpetualTokenMint(
        uint16 currencyId,
        uint88 amountToDeposit,
        bool useCashBalance
    ) external returns (uint) {
        return _mintPerpetualToken(currencyId, msg.sender, int(amountToDeposit), useCashBalance);
    }

    function perpetualTokenMintFor(
        uint16 currencyId,
        address recipient,
        uint88 amountToDeposit,
        bool useCashBalance
    ) external returns (uint) {
        return _mintPerpetualToken(currencyId, recipient, int(amountToDeposit), useCashBalance);
    }

    function perpetualTokenRedeem(
        uint16 currencyId,
        uint88 tokensToRedeem
    ) external returns (bool) {
        revert("UNIMPLMENTED");
    }

    function _mintPerpetualToken(
        uint currencyId,
        address recipient,
        int amountToDeposit,
        bool useCashBalance
    ) internal returns (uint) {
        uint blockTime = block.timestamp;

        // First check if the account can support the deposit
        // TODO: this is quite a bit of boilerplate
        AccountStorage memory recipientContext = accountContextMapping[recipient];
        BalanceState memory recipientBalance = BalanceHandler.buildBalanceState(
            recipient,
            currencyId,
            recipientContext.activeCurrencies
        );

        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolio(currencyId);
        AccountStorage memory accountContext = accountContextMapping[perpToken.tokenAddress];

        int tokensToMint = PerpetualToken.mintPerpetualToken(
            perpToken,
            accountContext,
            amountToDeposit,
            blockTime
        );

        if (useCashBalance && recipientBalance.storedCashBalance > 0) {
            if (recipientBalance.storedCashBalance > amountToDeposit) {
                recipientBalance.netCashChange = amountToDeposit.neg();
            } else {
                recipientBalance.netCashChange = recipientBalance.storedCashBalance.neg();
                recipientBalance.netCashTransfer = amountToDeposit.sub(recipientBalance.storedCashBalance);
            }
            
            // TODO: must free collateral check here
            if (recipientContext.hasDebt) {
                revert("UNIMPLMENTED");
            }
        } else {
            recipientBalance.netCashTransfer = amountToDeposit;
        }
        // TODO: should the balance context just hold the account address as well?
        recipientBalance.netPerpetualTokenTransfer = tokensToMint;
        recipientBalance.netCapitalDeposit = amountToDeposit;
        recipientBalance.finalize(recipient, recipientContext);
        accountContextMapping[recipient] = recipientContext;

        return SafeCast.toUint256(tokensToMint);
    }
}
