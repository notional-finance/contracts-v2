// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/FreeCollateral.sol";
import "../storage/AccountContextHandler.sol";

library FreeCollateralExternal {
    using AccountContextHandler for AccountStorage;

    function getFreeCollateralView(address account) external view returns (int) {
        uint blockTime = block.timestamp;
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        return FreeCollateral.getFreeCollateralView(account, accountContext, blockTime);
    }

    function checkFreeCollateralAndRevert(address account) external {
        uint blockTime = block.timestamp;
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);

        (int ethDenominatedFC, bool updateContext) = FreeCollateral.getFreeCollateralStateful(
            account,
            accountContext,
            blockTime
        );

        if (updateContext) accountContext.setAccountContext(account);

        require(ethDenominatedFC >= 0, "Insufficient free collateral");
    }

}