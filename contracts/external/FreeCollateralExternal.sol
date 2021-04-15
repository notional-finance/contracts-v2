// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../internal/AccountContextHandler.sol";
import "../internal/valuation/FreeCollateral.sol";

/// @title Externally deployed library for free collateral calculations
library FreeCollateralExternal {
    using AccountContextHandler for AccountContext;

    /// @notice Returns the ETH denominated free collateral of an account, represents the amount of
    /// debt that the account can incur before liquidation.
    /// @dev Called via the Views.sol method to return an account's free collateral. Does not work
    /// for the nToken
    /// @param account account to calculate free collateral for
    function getFreeCollateralView(address account) external view returns (int256) {
        uint256 blockTime = block.timestamp;
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        return FreeCollateral.getFreeCollateralView(account, accountContext, blockTime);
    }

    /// @notice Calculates free collateral and will revert if it falls below zero. If the account context
    /// must be updated due to changes in debt settings, will update
    /// @param account account to calculate free collateral for
    function checkFreeCollateralAndRevert(address account) external {
        uint256 blockTime = block.timestamp;
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);

        (int256 ethDenominatedFC, bool updateContext) =
            FreeCollateral.getFreeCollateralStateful(account, accountContext, blockTime);

        if (updateContext) accountContext.setAccountContext(account);

        require(ethDenominatedFC >= 0, "Insufficient free collateral");
    }
}
