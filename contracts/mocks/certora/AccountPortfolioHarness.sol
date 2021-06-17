// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/AccountContextHandler.sol";
import "../../internal/portfolio/BitmapAssetsHandler.sol";

contract AccountPortfolioHarness {
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

    function getAccountContextSlot(address account) external view returns (uint256) {
        bytes32 slot = keccak256(abi.encode(account, Constants.ACCOUNT_CONTEXT_STORAGE_OFFSET));
        uint256 data;

        assembly {
            data := sload(slot)
        }

        return data;
    }

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
