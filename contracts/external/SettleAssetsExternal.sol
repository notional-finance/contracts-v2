// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/portfolio/PortfolioHandler.sol";
import "../internal/balances/BalanceHandler.sol";
import "../internal/settlement/SettlePortfolioAssets.sol";
import "../internal/settlement/SettleBitmapAssets.sol";
import "../internal/AccountContextHandler.sol";

/// @notice External library for settling assets
library SettleAssetsExternal {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountContext;
    event AccountSettled(address indexed account);

    /// @notice Settles an account, returns the new account context object after settlement.
    /// @dev The memory location of the account context object is not the same as the one returned.
    function settleAccount(
        address account,
        AccountContext memory accountContext
    ) external returns (AccountContext memory) {
        // Defensive check to ensure that this is a valid settlement
        require(accountContext.mustSettleAssets());
        SettleAmount[] memory settleAmounts;
        PortfolioState memory portfolioState;

        if (accountContext.isBitmapEnabled()) {
            (int256 settledCash, uint256 blockTimeUTC0) =
                SettleBitmapAssets.settleBitmappedCashGroup(
                    account,
                    accountContext.bitmapCurrencyId,
                    accountContext.nextSettleTime,
                    block.timestamp
                );
            require(blockTimeUTC0 < type(uint40).max); // dev: block time utc0 overflow
            accountContext.nextSettleTime = uint40(blockTimeUTC0);

            settleAmounts = new SettleAmount[](1);
            settleAmounts[0] = SettleAmount(accountContext.bitmapCurrencyId, settledCash);
        } else {
            portfolioState = PortfolioHandler.buildPortfolioState(
                account,
                accountContext.assetArrayLength,
                0
            );
            settleAmounts = SettlePortfolioAssets.settlePortfolio(portfolioState, block.timestamp);
            accountContext.storeAssetsAndUpdateContext(account, portfolioState, false);
        }

        BalanceHandler.finalizeSettleAmounts(account, accountContext, settleAmounts);

        emit AccountSettled(account);

        return accountContext;
    }
}
