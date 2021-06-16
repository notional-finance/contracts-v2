// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../contracts/internal/AccountContextHandler.sol";

contract AccountPortfolioMock {
    using AccountContextHandler for AccountContext;

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

    function setActiveCurrency(address account, uint256 currencyId, bool isActive, bytes2 flags) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.setActiveCurrency(currencyId, isActive, flags);
        accountContext.setAccountContext(account);
    }

    function storeArrayAssets(address account, PortfolioState memory portfolioState, bool isLiquidation)
        public
        returns (AccountContext memory)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.storeAssetsAndUpdateContext(account, portfolioState, isLiquidation);
        accountContext.setAccountContext(account);

        return accountContext;
    }

    // todo: add bitmap mocks
    // todo: add settlement?

}