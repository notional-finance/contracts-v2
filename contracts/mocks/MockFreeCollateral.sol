// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../actions/FreeCollateralExternal.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/AccountContextHandler.sol";
import "./MockAssetHandler.sol";

contract MockFreeCollateral is MockAssetHandler {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;

    function getAccountContext(
        address account
    ) external view returns (AccountStorage memory) {
        return AccountContextHandler.getAccountContext(account);
    }

    function enableBitmapForAccount(
        address account,
        uint currencyId
    ) external {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.enableBitmapForAccount(account, currencyId);
        accountContext.setAccountContext(account);
    }

    function setifCashAsset(
        address account,
        uint currencyId,
        uint maturity,
        int notional,
        uint blockTime
    ) external {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        bytes32 bitmap = BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
        if (accountContext.nextSettleTime != 0 && accountContext.nextSettleTime != CashGroup.getTimeUTC0(blockTime)) {
            revert(); // dev: invalid block time for test
        }
        accountContext.nextSettleTime = uint40(CashGroup.getTimeUTC0(blockTime));

        bitmap = BitmapAssetsHandler.setifCashAsset(
            account, currencyId, maturity, accountContext.nextSettleTime, notional, bitmap
        );
        accountContext.setAccountContext(account);
        BitmapAssetsHandler.setAssetsBitmap(account, currencyId, bitmap);
    }

    function setETHRateMapping(
        uint id,
        ETHRateStorage calldata rs
    ) external {
        underlyingToETHRateMapping[id] = rs;
    }

    function setPortfolio(
        address account,
        PortfolioAsset[] memory assets
    ) external {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory portfolioState = PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);
        portfolioState.newAssets = assets;
        accountContext.storeAssetsAndUpdateContext(account, portfolioState);
        accountContext.setAccountContext(account);
    }

    function setBalance(
        address account,
        uint currencyId,
        int cashBalance,
        int perpTokenBalance
    ) external {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.setActiveCurrency(currencyId, true, AccountContextHandler.ACTIVE_IN_BALANCES_FLAG);
        accountContext.setAccountContext(account);

        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));

        bytes32 data = (
            (bytes32(uint(perpTokenBalance))) |
            (bytes32(0) << 96) |
            (bytes32(cashBalance) << 128)
        );

        assembly { sstore(slot, data) }
    }

    function getFreeCollateralView(
        address account
    ) external view returns (int) {
        return FreeCollateralExternal.getFreeCollateralView(account);
    }

    function checkFreeCollateralAndRevert(
        address account
    ) external {
        FreeCollateralExternal.checkFreeCollateralAndRevert(account);
    }

}