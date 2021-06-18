// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/AccountContextHandler.sol";
import "../../internal/portfolio/BitmapAssetsHandler.sol";

contract AccountPortfolioHarness {
    using AccountContextHandler for AccountContext;

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

    function getAssetsBitmap(address account) external view returns (bytes32) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        return BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId);
    }

    function getAccountContext(address account) external view returns (AccountContext memory) {
        return AccountContextHandler.getAccountContext(account);
    }

    function enableBitmapForAccount(
        address account,
        uint256 currencyId,
        uint256 blockTime
    ) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.enableBitmapForAccount(account, currencyId, blockTime);
        accountContext.setAccountContext(account);
    }

    function setActiveCurrency(
        address account,
        uint256 currencyId,
        bool isActive,
        bytes2 flags
    ) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.setActiveCurrency(currencyId, isActive, flags);
        accountContext.setAccountContext(account);
    }

    function storeArrayAssets(
        address account,
        PortfolioState memory portfolioState,
        bool isLiquidation
    ) public returns (AccountContext memory) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.storeAssetsAndUpdateContext(account, portfolioState, isLiquidation);
        accountContext.setAccountContext(account);

        return accountContext;
    }

    // todo: add bitmap mocks
    // todo: add settlement?
}
