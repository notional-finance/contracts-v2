// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/AccountContextHandler.sol";
import "../../internal/portfolio/BitmapAssetsHandler.sol";

contract GetterSetterHarness {
    using AccountContextHandler for AccountContext;

    function setAccountContext(
        address account,
        uint40 nextSettleTime,
        uint8 hasDebt,
        uint8 assetArrayLength,
        uint16 bitmapCurrencyId,
        uint144 activeCurrencies
    ) external {
        AccountContext memory accountContext =
            AccountContext({
                nextSettleTime: nextSettleTime,
                hasDebt: bytes1(hasDebt),
                assetArrayLength: assetArrayLength,
                bitmapCurrencyId: bitmapCurrencyId,
                activeCurrencies: bytes18(activeCurrencies)
            });
        accountContext.setAccountContext(account);
    }

    function getAccountContext(address account) external view returns (AccountContext memory) {
        return AccountContextHandler.getAccountContext(account);
    }

    // TODO: remove these once we can handle bytesNN natively
    function getNextSettleTime(address account) external view returns (uint40) {
        return AccountContextHandler.getAccountContext(account).nextSettleTime;
    }

    function getHasDebt(address account) external view returns (uint8) {
        return uint8(AccountContextHandler.getAccountContext(account).hasDebt);
    }

    function getAssetArrayLength(address account) external view returns (uint8) {
        return AccountContextHandler.getAccountContext(account).assetArrayLength;
    }

    function getBitmapCurrency(address account) external view returns (uint16) {
        return AccountContextHandler.getAccountContext(account).bitmapCurrencyId;
    }

    function getActiveCurrencies(address account) external view returns (uint144) {
        return uint144(AccountContextHandler.getAccountContext(account).activeCurrencies);
    }
}
