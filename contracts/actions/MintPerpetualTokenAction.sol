// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/PerpetualToken.sol";
import "../math/SafeInt256.sol";
import "../storage/StorageLayoutV1.sol";
import "../storage/BalanceHandler.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MintPerpetualTokenAction is StorageLayoutV1, ReentrancyGuard {
    using SafeInt256 for int256;
    using BalanceHandler for BalanceState;

    function perpetualTokenMintViaBatch(
        uint16 currencyId,
        uint88 amountToDepositInternalPrecision
    ) external nonReentrant returns (int) {
        require(msg.sender == address(this), "Unauthorized caller");
        return _mintPerpetualToken(currencyId, amountToDepositInternalPrecision);
    }

    function perpetualTokenMint(
        uint16 currencyId,
        uint88 amountToDepositExternalPrecision,
        bool useCashBalance
    ) external nonReentrant returns (uint) {
        address recipient = msg.sender;
        AccountStorage memory recipientContext = accountContextMapping[recipient];
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
        recipientBalance.netPerpetualTokenTransfer = tokensMinted;
        recipientBalance.finalize(recipient, recipientContext, false);
        accountContextMapping[recipient] = recipientContext;

        // TODO: must free collateral check here
        if (recipientContext.hasDebt) {
            revert("UNIMPLMENTED");
        }

        return uint(tokensMinted);
    }

    function _mintPerpetualToken(
        uint currencyId,
        int amountToDepositInternal
    ) internal returns (int) {
        uint blockTime = block.timestamp;
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolio(currencyId);
        AccountStorage memory perpTokenContext = accountContextMapping[perpToken.tokenAddress];
        AssetStorage[] storage perpTokenAssetStorage = assetArrayMapping[perpToken.tokenAddress];

        int tokensMinted = PerpetualToken.mintPerpetualToken(
            perpToken,
            perpTokenContext,
            amountToDepositInternal,
            blockTime,
            perpTokenAssetStorage
        );
        require(tokensMinted >= 0, "Invalid token amount");

        return tokensMinted;
    }
}
