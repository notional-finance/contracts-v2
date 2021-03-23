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

    function getActiveCurrencyBytes(
        AccountStorage memory accountContext
    ) external pure returns (bytes20) {
        return accountContext.getActiveCurrencyBytes();
    }

    function clearPortfolioActiveFlags(
        bytes18 activeCurrencies
    ) external pure returns (bytes18) {
        return AccountContextHandler.clearPortfolioActiveFlags(activeCurrencies);
    }

    function setActiveCurrency(
        bytes18 activeCurrencies,
        uint currencyId,
        bool isActive,
        bytes2 flags
    ) external pure returns (bytes18) {
        AccountStorage memory accountContext = AccountStorage(0, 0x00, 0, 0, activeCurrencies);
        accountContext.setActiveCurrency(currencyId, isActive, flags);

        // Assert that the currencies are in order
        bytes18 currencies = accountContext.activeCurrencies;
        uint lastCurrency;
        while (currencies != 0x0) {
            uint thisCurrency = uint(uint16(bytes2(currencies) & AccountContextHandler.UNMASK_FLAGS));
            assert (thisCurrency != 0);
            // Either flag must be set
            assert (
                ((bytes2(currencies) & AccountContextHandler.ACTIVE_IN_PORTFOLIO_FLAG) == AccountContextHandler.ACTIVE_IN_PORTFOLIO_FLAG)
                || ((bytes2(currencies) & AccountContextHandler.ACTIVE_IN_BALANCES_FLAG) == AccountContextHandler.ACTIVE_IN_BALANCES_FLAG)
            );
            // currencies are in order
            assert (thisCurrency > lastCurrency);

            if (isActive && currencyId == thisCurrency) {
                assert (bytes2(currencies) & flags == flags);
            } else if (!isActive && currencyId == thisCurrency) {
                assert (bytes2(currencies) & flags != flags);
            }

            lastCurrency = thisCurrency;
            currencies = currencies << 16;
        }

        return accountContext.activeCurrencies;
    }

}
