// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/AccountContextHandler.sol";
import "../internal/portfolio/BitmapAssetsHandler.sol";

interface IAccountContext {
    struct AccountContextOld {
        uint40 nextSettleTime;
        bytes1 hasDebt;
        uint8 assetArrayLength;
        uint16 bitmapCurrencyId;
        bytes18 activeCurrencies;
    }

    function getAccountContext(address account) external view returns (AccountContextOld memory);
}

contract MockAccountContextReader {
    function getAccountContext(address account) external view returns (IAccountContext.AccountContextOld memory) {
        // This is just here to get the signature
    }

    function getAccountContextTest(address account, address proxy) external view returns (IAccountContext.AccountContextOld memory) {
        return IAccountContext(proxy).getAccountContext(account);
    }
}

contract MockAccountContextHandler {
    using AccountContextHandler for AccountContext;

    function setAssetBitmap(
        address account,
        uint256 id,
        bytes32 bitmap
    ) external {
        BitmapAssetsHandler.setAssetsBitmap(account, id, bitmap);
    }

    function enableBitmapForAccount(
        address account,
        uint16 currencyId,
        uint256 blockTime
    ) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.enableBitmapForAccount(currencyId, blockTime);
        accountContext.setAccountContext(account);
    }

    function getAccountContext(address account) external view returns (AccountContext memory) {
        return AccountContextHandler.getAccountContext(account);
    }

    function setAccountContext(AccountContext memory accountContext, address account) external {
        return accountContext.setAccountContext(account);
    }

    function isActiveInBalances(AccountContext memory accountContext, uint256 currencyId)
        external
        pure
        returns (bool)
    {
        return accountContext.isActiveInBalances(currencyId);
    }

    function clearPortfolioActiveFlags(bytes18 activeCurrencies) external pure returns (bytes18) {
        return AccountContextHandler._clearPortfolioActiveFlags(activeCurrencies);
    }

    function setActiveCurrency(
        bytes18 activeCurrencies,
        uint256 currencyId,
        bool isActive,
        bytes2 flags,
        uint16 bitmapId
    ) external pure returns (bytes18) {
        AccountContext memory accountContext =
            AccountContext(0, 0x00, 0, bitmapId, activeCurrencies, false);
        accountContext.setActiveCurrency(currencyId, isActive, flags);

        // Assert that the currencies are in order
        bytes18 currencies = accountContext.activeCurrencies;
        uint256 lastCurrency;
        while (currencies != 0x0) {
            uint256 thisCurrency = uint256(uint16(bytes2(currencies) & Constants.UNMASK_FLAGS));
            assert(thisCurrency != 0);
            // Either flag must be set
            assert(
                ((bytes2(currencies) & Constants.ACTIVE_IN_PORTFOLIO) ==
                    Constants.ACTIVE_IN_PORTFOLIO) ||
                    ((bytes2(currencies) & Constants.ACTIVE_IN_BALANCES) ==
                        Constants.ACTIVE_IN_BALANCES)
            );
            // currencies are in order
            assert(thisCurrency > lastCurrency);

            if (isActive && currencyId == thisCurrency) {
                assert(bytes2(currencies) & flags == flags);
            } else if (!isActive && currencyId == thisCurrency) {
                assert(bytes2(currencies) & flags != flags);
            }

            lastCurrency = thisCurrency;
            currencies = currencies << 16;
        }

        // Bitmap id should never change in this method
        assert(accountContext.bitmapCurrencyId == bitmapId);

        return accountContext.activeCurrencies;
    }

    // function findCurrency(bytes18 activeCurrencies, uint256 currencyId) internal pure {
    //     uint offset;
    //     uint256 currencies = activeCurrencies;

    //     if (uint16 (l >> 112) > element) { l >>= 128; offset += 128; }
    //     if (uint16 (l >> 48) > element ) { l >>= 64; offset += 64; }
    //     if (uint16 (l >> 16) > element ) { l >>= 32; offset += 32; }
    //     if (uint16 (l) > element ) { l >>= 16; offset += 16; }

    //     uint16 e = uint16 (l);
    // }
}
