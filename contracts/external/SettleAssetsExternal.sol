// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../internal/portfolio/PortfolioHandler.sol";
import "../internal/balances/BalanceHandler.sol";
import "../internal/settlement/SettlePortfolioAssets.sol";
import "../internal/settlement/SettleBitmapAssets.sol";
import "../internal/AccountContextHandler.sol";

/// @notice External library for settling assets, presents different options for calling methods
/// depending on their data requirements. Note that bitmapped portfolios will always be settled
/// and an empty portfolio state will be returned.
library SettleAssetsExternal {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountContext;
    event AccountSettled(address indexed account);

    function settleAssetsAndFinalize(address account) external returns (AccountContext memory) {
        // prettier-ignore
        (
            AccountContext memory accountContext,
            /* SettleAmount[] memory settleAmounts */,
            /* PortfolioState memory portfolioState */
        ) = _settleAccount(account, true, true);

        return accountContext;
    }

    function settleAssetsAndStorePortfolio(address account)
        external
        returns (AccountContext memory, SettleAmount[] memory)
    {
        // prettier-ignore
        (
            AccountContext memory accountContext,
            SettleAmount[] memory settleAmounts,
            /* PortfolioState memory portfolioState */
        ) = _settleAccount(account, false, true);

        return (accountContext, settleAmounts);
    }

    function settleAssetsAndReturnPortfolio(address account)
        external
        returns (AccountContext memory, PortfolioState memory)
    {
        // prettier-ignore
        (
            AccountContext memory accountContext,
            /* SettleAmount[] memory settleAmounts */,
            PortfolioState memory portfolioState
        ) = _settleAccount(account, true, false);

        return (accountContext, portfolioState);
    }

    function settleAssetsAndReturnAll(address account)
        external
        returns (
            AccountContext memory,
            SettleAmount[] memory,
            PortfolioState memory
        )
    {
        return _settleAccount(account, false, false);
    }

    function _settleAccount(
        address account,
        bool finalizeAmounts,
        bool finalizePortfolio
    )
        private
        returns (
            AccountContext memory,
            SettleAmount[] memory,
            PortfolioState memory
        )
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        SettleAmount[] memory settleAmounts;
        PortfolioState memory portfolioState;

        if (accountContext.bitmapCurrencyId != 0) {
            settleAmounts = _settleBitmappedAccountStateful(
                account,
                accountContext.bitmapCurrencyId,
                accountContext.nextSettleTime
            );
        } else {
            portfolioState = PortfolioHandler.buildPortfolioState(
                account,
                accountContext.assetArrayLength,
                0
            );
            settleAmounts = SettlePortfolioAssets.settlePortfolio(portfolioState, block.timestamp);

            if (finalizePortfolio) {
                accountContext.storeAssetsAndUpdateContext(account, portfolioState, false);
            }
        }

        if (finalizeAmounts) {
            BalanceHandler.finalizeSettleAmounts(account, accountContext, settleAmounts);
        }

        emit AccountSettled(account);

        return (accountContext, settleAmounts, portfolioState);
    }

    function _settleBitmappedAccountStateful(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime
    ) internal returns (SettleAmount[] memory) {
        (bytes32 assetsBitmap, int256 settledCash) = SettleBitmapAssets.settleBitmappedCashGroup(
            account,
            currencyId,
            nextSettleTime,
            block.timestamp
        );

        BitmapAssetsHandler.setAssetsBitmap(account, currencyId, assetsBitmap);
        SettleAmount[] memory settleAmounts = new SettleAmount[](1);
        settleAmounts[0].currencyId = currencyId;
        settleAmounts[0].netCashChange = settledCash;
        return settleAmounts;
    }
}
