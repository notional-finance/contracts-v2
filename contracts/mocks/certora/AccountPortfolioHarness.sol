// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/AccountContextHandler.sol";
import "../../internal/portfolio/BitmapAssetsHandler.sol";
import "../../internal/portfolio/PortfolioHandler.sol";
import "../../internal/markets/DateTime.sol";

contract AccountPortfolioHarness {
    using AccountContextHandler for AccountContext;
    using PortfolioHandler for PortfolioState;

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

    function getAssetsBitmap(address account) external view returns (uint256) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        return
            uint256(BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId));
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

    // This is just a harness for getting the settlement date
    function getSettlementDate(uint256 assetType, uint256 maturity) public returns (uint256) {
        return
            AssetHandler.getSettlementDate(
                PortfolioAsset({
                    currencyId: 0,
                    maturity: maturity,
                    assetType: assetType,
                    notional: 0,
                    storageSlot: 0,
                    storageState: AssetStorageState.NoChange
                })
            );
    }

    function getMaturityAtBitNum(address account, uint256 bitNum) public returns (uint256) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        return DateTime.getMaturityFromBitNum(accountContext.nextSettleTime, bitNum);
    }

    function getifCashNotional(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) external view returns (int256) {
        return BitmapAssetsHandler.getifCashNotional(account, currencyId, maturity);
    }

    // Adds one asset into the array portfolio at a time
    function addArrayAsset(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 assetType,
        int256 notional
    ) public {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);

        PortfolioState memory portfolioState =
            // TODO: need to test isNewHint somehow...
            PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);
        portfolioState.addAsset(currencyId, maturity, assetType, notional, false);

        // TODO: disable liquidation on this, will test separately
        accountContext.storeAssetsAndUpdateContext(account, portfolioState, false);
        accountContext.setAccountContext(account);
    }

    function addBitmapAsset(
        address account,
        uint256 maturity,
        int256 notional
    ) public {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        bytes32 ifCashBitmap =
            BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId);
        int256 finalfCashAmount;

        (ifCashBitmap, finalfCashAmount) = BitmapAssetsHandler.addifCashAsset(
            account,
            accountContext.bitmapCurrencyId,
            maturity,
            accountContext.nextSettleTime,
            notional,
            ifCashBitmap
        );

        // This is a replication of logic in trading action...
        if (finalfCashAmount < 0) {
            accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_ASSET_DEBT;
        }

        BitmapAssetsHandler.setAssetsBitmap(account, accountContext.bitmapCurrencyId, ifCashBitmap);
    }

    // todo: add settlement methods here...

    /*
    function setActiveCurrency2(address account, bytes18 activeCurrencies) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.activeCurrencies = activeCurrencies;
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
    */
}
