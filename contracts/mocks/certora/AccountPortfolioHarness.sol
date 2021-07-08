// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/AccountContextHandler.sol";
import "../../internal/balances/BalanceHandler.sol";
import "../../internal/portfolio/BitmapAssetsHandler.sol";
import "../../internal/portfolio/PortfolioHandler.sol";
import "../../internal/markets/DateTime.sol";

contract AccountPortfolioHarness {
    using AccountContextHandler for AccountContext;
    using PortfolioHandler for PortfolioState;
    using BalanceHandler for BalanceState;


    // todo : might need this as a mapping form address
    AccountContext public symbolicAccountContext;
    PortfolioState public symbolicPortfolioState;

    function getNextSettleTime(address account) external view returns (uint40) {
        //return AccountContextHandler.getAccountContext(account).nextSettleTime;
        return symbolicAccountContext.nextSettleTime;
    }

    function getHasDebt(address account) external view returns (uint8) {
        return uint8(symbolicAccountContext.hasDebt);
    }

    function getAssetArrayLength(address account) external view returns (uint8) {
        return symbolicAccountContext.assetArrayLength;
    }

    function getBitmapCurrency(address account) external view returns (uint16) {
        return symbolicAccountContext.bitmapCurrencyId;
    }

    function getActiveCurrencies(address account) external view returns (uint144) {
        return uint144(symbolicAccountContext.activeCurrencies);
    }

    function getAssetsBitmap(address account) external view returns (uint256) {
        AccountContext memory accountContext = symbolicAccountContext;
        return
            uint256(BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId));
    }

    function getAccountContext(address account) external view returns (AccountContext memory) {
        return symbolicAccountContext;
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
        AccountContext memory accountContext = symbolicAccountContext;
        return DateTime.getMaturityFromBitNum(accountContext.nextSettleTime, bitNum);
    }

    function getifCashNotional(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) external view returns (int256) {
        return BitmapAssetsHandler.getifCashNotional(account, currencyId, maturity);
    }

    function getCashBalance(address account, uint256 currencyId) public returns (int256) {
        // prettier-ignore
        (int256 cashBalance, /* */, /* */, /* */) = BalanceHandler.getBalanceStorage(account, currencyId);
        return cashBalance;
    }

    function getNTokenBalance(address account, uint256 currencyId) public returns (int256) {
        // prettier-ignore
        (/* */, int256 nTokenBalance, /* */, /* */) = BalanceHandler.getBalanceStorage(account, currencyId);
        return nTokenBalance;
    }

    function getLastClaimTime(address account, uint256 currencyId) public returns (uint256) {
        // prettier-ignore
        (/* */, /* */, uint256 lastClaimTime, /* */) = BalanceHandler.getBalanceStorage(account, currencyId);
        return lastClaimTime;
    }

    function getLastClaimSupply(address account, uint256 currencyId) public returns (uint256) {
        // prettier-ignore
        (/* */, /* */, /* */, uint256 lastClaimSupply) = BalanceHandler.getBalanceStorage(account, currencyId);
        return lastClaimSupply;
    }


    function getStoredAsset(address account, uint256 i) public view returns (uint256) {
        return symbolicPortfolioState.storedAssets[i].currencyId;
    }
    /** State Changing Methods **/

    function enableBitmapForAccount(
        address account,
        uint256 currencyId,
        uint256 blockTime
    ) external {
        AccountContext memory accountContext = symbolicAccountContext;
        accountContext.enableBitmapForAccount(account, currencyId, blockTime);
        symbolicAccountContext = accountContext;
    }

    // Adds one asset into the array portfolio at a time
    function addArrayAsset(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 assetType,
        int256 notional
    ) public {
        AccountContext memory accountContext = symbolicAccountContext;

        PortfolioState memory portfolioState = symbolicPortfolioState;
            
        portfolioState.addAsset(currencyId, maturity, assetType, notional, false);

        symbolicAccountContext = accountContext;
    }

    function addBitmapAsset(
        address account,
        uint256 maturity,
        int256 notional
    ) public {
        AccountContext memory accountContext = symbolicAccountContext;
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
        symbolicAccountContext = accountContext;
    }

    function finalizeCashBalance(
        address account,
        uint256 currencyId,
        int256 netCashChange,
        int256 netAssetTransferInternalPrecision,
        bool redeemToUnderlying
    ) external {
        AccountContext memory accountContext = symbolicAccountContext;
        BalanceState memory balanceState;
        balanceState.loadBalanceState(account, currencyId, accountContext);
        balanceState.netCashChange = netCashChange;
        balanceState.netAssetTransferInternalPrecision = netAssetTransferInternalPrecision;

        balanceState.finalize(account, accountContext, redeemToUnderlying);
        symbolicAccountContext = accountContext;
    }

    function setBalanceStorageForSettleCashDebt(
        address account,
        uint256 currencyId,
        int256 amountToSettleAsset
    ) external {
        AccountContext memory accountContext = symbolicAccountContext;
        BalanceHandler.setBalanceStorageForSettleCashDebt(
            account,
            currencyId,
            amountToSettleAsset,
            accountContext
        );
        symbolicAccountContext = accountContext;
    }


    // todo: add _clearPortfolioActiveFlags?
    // todo: add settlement methods here...
    // include finalizeSettleAmounts

    /*
    function setActiveCurrency2(address account, bytes18 activeCurrencies) external {
        AccountContext memory accountContext = symbolicAccountContext;
        accountContext.activeCurrencies = activeCurrencies;
        accountContext.setAccountContext(account);
    }

    function setActiveCurrency(
        address account,
        uint256 currencyId,
        bool isActive,
        bytes2 flags
    ) external {
        AccountContext memory accountContext = symbolicAccountContext;
        accountContext.setActiveCurrency(currencyId, isActive, flags);
        accountContext.setAccountContext(account);
    }
    */
}
