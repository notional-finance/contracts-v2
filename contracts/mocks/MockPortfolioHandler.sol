// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../internal/AccountContextHandler.sol";
import "../internal/portfolio/PortfolioHandler.sol";
import "../global/StorageLayoutV1.sol";

contract MockPortfolioHandler is StorageLayoutV1 {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;

    function getAssetArray(address account) external view returns (PortfolioAsset[] memory) {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        return PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength);
    }

    function addAsset(
        PortfolioState memory portfolioState,
        uint256 currencyId,
        uint256 maturity,
        uint256 assetType,
        int256 notional,
        bool isNewHint
    ) public pure returns (PortfolioState memory) {
        portfolioState.addAsset(currencyId, maturity, assetType, notional, isNewHint);

        return portfolioState;
    }

    function getAccountContext(address account) external view returns (AccountStorage memory) {
        return AccountContextHandler.getAccountContext(account);
    }

    function storeAssets(address account, PortfolioState memory portfolioState)
        public
        returns (AccountStorage memory)
    {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.storeAssetsAndUpdateContext(account, portfolioState);
        accountContext.setAccountContext(account);

        return accountContext;
    }

    function deleteAsset(PortfolioState memory portfolioState, uint256 index)
        public
        pure
        returns (PortfolioState memory)
    {
        portfolioState.deleteAsset(index);

        return portfolioState;
    }

    function getEncodedId(PortfolioAsset memory asset) public pure returns (uint256) {
        return PortfolioHandler.getEncodedId(asset);
    }

    function buildPortfolioState(address account, uint256 newAssetsHint)
        public
        view
        returns (PortfolioState memory)
    {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);

        return
            PortfolioHandler.buildPortfolioState(
                account,
                accountContext.assetArrayLength,
                newAssetsHint
            );
    }
}
