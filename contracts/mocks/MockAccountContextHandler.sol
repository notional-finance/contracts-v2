// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/AccountContextHandler.sol";

contract MockAccountContextHandler {
    using AccountContextHandler for AccountStorage;

    function getAccountContext(
        address account
    ) external view returns (AccountStorage memory) {
        return AccountContextHandler.getAccountContext(account);
    }

    function setAccountContext(
        AccountStorage memory accountContext,
        address account
    ) external {
        return accountContext.setAccountContext(account);
    }

    function isActiveCurrency(
        AccountStorage memory accountContext,
        uint currencyId
    ) external pure returns (bool) {
        return accountContext.isActiveCurrency(currencyId);
    }

    function setActiveCurrency(
        bytes18 activeCurrencies,
        uint currencyId,
        bool isActive
    ) external pure returns (bytes18) {
        AccountStorage memory accountContext = AccountStorage(0, false, 0, 0, activeCurrencies);
        accountContext.setActiveCurrency(currencyId, isActive);
        assert (accountContext.isActiveCurrency(currencyId) == isActive);

        // Assert that the currencies are in order
        bytes18 currencies = accountContext.activeCurrencies;
        uint lastCurrency;
        while (currencies != 0x0) {
            uint thisCurrency = uint(uint16(bytes2(currencies)));
            assert (thisCurrency > lastCurrency);
            lastCurrency = thisCurrency;
            currencies = currencies << 16;
        }

        return accountContext.activeCurrencies;
    }

    function getAllBalances(
        bytes18 activeCurrencies,
        address account,
        uint16 bitmapCurrencyId
    ) external view returns (BalanceState[] memory) {
        AccountStorage memory accountContext = AccountStorage(0, false, 0, bitmapCurrencyId, activeCurrencies);
        BalanceState[] memory bs = accountContext.getAllBalances(account);

        for (uint i; i < bs.length; i++) {
            // Assert that currencies are ordered
            if (i != 0) assert (bs[i - 1].currencyId < bs[i].currencyId);
        }

        return bs;
    }

}
