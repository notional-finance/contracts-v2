// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageLayoutV1.sol";

struct BalanceContext {
    uint currencyId;
    address assetTokenAddress;
    bool tokenHasTransferFee;
    int balance;
}

/**
 * @dev Reads storage parameters and creates context structs for different actions.
 */
contract StorageReader is StorageLayoutV1 {

    /**
     * @notice Used for deposit or withdraw actions only. No exchange rates required.
     * For market trades use `getMarketTradeContext` instead.
     */
    function getBalanceContext(
        address account,
        uint[] calldata currencyIds
    ) internal view returns (BalanceContext[] memory) {
        BalanceContext[] memory context = new BalanceContext[](currencyIds.length);
        CurrencyStorage memory currency;

        for (uint i; i < currencyIds.length; i++) {
            context[i].currencyId = currencyIds[i];
            // Storage Read
            currency = currenciesMapping[currencyIds[i]];
            context[i].assetTokenAddress = currency.assetTokenAddress;
            context[i].tokenHasTransferFee = currency.tokenHasTransferFee;
            // Storage Read
            context[i].balance = accountBalanceMapping[account][currency.assetTokenAddress];
        }

        return context;
    }

    // function getAssetTransferContext() 
    // function getMarketTradeContext() 
    // function getFinalizeContext()
}