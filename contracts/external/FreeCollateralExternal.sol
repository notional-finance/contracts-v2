// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../global/Deployments.sol";
import "../external/SettleAssetsExternal.sol";
import "../internal/AccountContextHandler.sol";
import "../internal/valuation/FreeCollateral.sol";

/// @title Externally deployed library for free collateral calculations
library FreeCollateralExternal {
    using AccountContextHandler for AccountContext;
    // Grace period after a sequencer downtime has occurred
    uint256 internal constant SEQUENCER_UPTIME_GRACE_PERIOD = 1 hours;

    function _checkSequencer() private view {
        // See: https://docs.chain.link/data-feeds/l2-sequencer-feeds/
        if (address(Deployments.SEQUENCER_UPTIME_ORACLE) != address(0)) {
            (
                /*uint80 roundID*/,
                int256 answer,
                uint256 startedAt,
                /*uint256 updatedAt*/,
                /*uint80 answeredInRound*/
            ) = Deployments.SEQUENCER_UPTIME_ORACLE.latestRoundData();
            require(answer == 0, "Sequencer Down");
            require(SEQUENCER_UPTIME_GRACE_PERIOD < block.timestamp - startedAt, "Sequencer Grace Period");
        }
    }

    /// @notice Returns the ETH denominated free collateral of an account, represents the amount of
    /// debt that the account can incur before liquidation. If an account's assets need to be settled this
    /// will revert, either settle the account or use the off chain SDK to calculate free collateral.
    /// @dev Called via the Views.sol method to return an account's free collateral. Does not work
    /// for the nToken, the nToken does not have an account context.
    /// @param account account to calculate free collateral for
    /// @return total free collateral in ETH w/ 8 decimal places
    /// @return array of net local values in asset values ordered by currency id
    function getFreeCollateralView(address account)
        external
        view
        returns (int256, int256[] memory)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        // The internal free collateral function does not account for settled assets. The Notional SDK
        // can calculate the free collateral off chain if required at this point.
        require(!accountContext.mustSettleAssets(), "Assets not settled");
        return FreeCollateral.getFreeCollateralView(account, accountContext, block.timestamp);
    }

    /// @notice Calculates free collateral and will revert if it falls below zero. If the account context
    /// must be updated due to changes in debt settings, will update. Cannot check free collateral if assets
    /// need to be settled first.
    /// @dev Cannot be called directly by users, used during various actions that require an FC check. Must be
    /// called before the end of any transaction for accounts where FC can decrease.
    /// @param account account to calculate free collateral for
    function checkFreeCollateralAndRevert(address account) external {
        // Prevents new debt positions from being initiated if the sequencer is down, only applies to L2 environments
        // like Arbitrum and Optimism where this is a concern. Accounts with no risk do not get a free
        // collateral check and will bypass this check.
        _checkSequencer();

        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        require(!accountContext.mustSettleAssets(), "Assets not settled");

        (int256 ethDenominatedFC, bool updateContext) =
            FreeCollateral.getFreeCollateralStateful(account, accountContext, block.timestamp);

        if (updateContext) {
            accountContext.setAccountContext(account);
        }

        require(ethDenominatedFC >= 0, "Insufficient free collateral");
    }

    /// @notice Calculates liquidation factors for an account
    /// @dev Only called internally by liquidation actions, does some initial validation of currencies. If a currency is
    /// specified that the account does not have, a asset available figure of zero will be returned. If this is the case then
    /// liquidation actions will revert.
    /// @dev an ntoken account will return 0 FC and revert if called
    /// @param account account to liquidate
    /// @param localCurrencyId currency that the debts are denominated in
    /// @param collateralCurrencyId collateral currency to liquidate against, set to zero in the case of local currency liquidation
    /// @return accountContext the accountContext of the liquidated account
    /// @return factors struct of relevant factors for liquidation
    /// @return portfolio the portfolio array of the account (bitmap accounts will return an empty array)
    function getLiquidationFactors(
        address account,
        uint256 localCurrencyId,
        uint256 collateralCurrencyId
    )
        external
        returns (
            AccountContext memory accountContext,
            LiquidationFactors memory factors,
            PortfolioAsset[] memory portfolio
        )
    {
        // Prevents new liquidations from being initiated if the sequencer is down, only applies to L2 environments
        // like Arbitrum and Optimism where this is a concern.
        _checkSequencer();

        accountContext = AccountContextHandler.getAccountContext(account);
        if (accountContext.mustSettleAssets()) {
            accountContext = SettleAssetsExternal.settleAccount(account, accountContext);
        }

        if (accountContext.isBitmapEnabled()) {
            // A bitmap currency can only ever hold debt in this currency
            require(localCurrencyId == accountContext.bitmapCurrencyId);
        }

        (factors, portfolio) = FreeCollateral.getLiquidationFactors(
            account,
            accountContext,
            block.timestamp,
            localCurrencyId,
            collateralCurrencyId
        );
    }
}
