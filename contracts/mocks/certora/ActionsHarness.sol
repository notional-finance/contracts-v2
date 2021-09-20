// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../external/actions/AccountAction.sol";

// Harness to simulate the free collateral check
// TODO: how to inject this as the free collateral library?
contract FreeCollateralExternalHarness {
    mapping(address => bool) shouldRevert;

    function shouldAccountRevert(address account) external view returns (bool) {
        return shouldRevert[account];
    }

    function checkFreeCollateralAndRevert(address account) external {
        if (shouldRevert[account]) revert("Insufficient free collateral");
    }
}

contract SettleAssetsExternalHarness {
    mapping(address => bool) didSettle;

    function didAccountSettle(address account) external view returns (bool) {
        return didSettle[account];
    }

    function settleAssetsAndFinalize(address account, AccountContext memory accountContext)
        external
        returns (AccountContext memory)
    {
        didSettle[account] = true;
        return accountContext;
    }

    function settleAssetsAndStorePortfolio(address account, AccountContext memory accountContext)
        external
        returns (AccountContext memory, SettleAmount[] memory)
    {
        SettleAmount[] memory settleAmounts;
        didSettle[account] = true;

        return (accountContext, settleAmounts);
    }

    function settleAssetsAndReturnPortfolio(address account, AccountContext memory accountContext)
        external
        returns (AccountContext memory, PortfolioState memory)
    {
        PortfolioState memory portfolioState;
        didSettle[account] = true;

        return (accountContext, portfolioState);
    }

    function settleAssetsAndReturnAll(address account, AccountContext memory accountContext)
        external
        returns (
            AccountContext memory,
            SettleAmount[] memory,
            PortfolioState memory
        )
    {
        SettleAmount[] memory settleAmounts;
        PortfolioState memory portfolioState;
        didSettle[account] = true;
        return (accountContext, settleAmounts, portfolioState);
    }
}

contract ActionsHarness is AccountAction {}
