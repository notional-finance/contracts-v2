// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/AccountContextHandler.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/StorageLayoutV1.sol";

contract MockPortfolioHandler is StorageLayoutV1 {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;

    function getAssetArray(address account) external view returns (PortfolioAsset[] memory) {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        return PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength);
    }

    function addAsset(
        PortfolioState memory portfolioState,
        uint currencyId,
        uint maturity,
        uint assetType,
        int notional,
        bool isNewHint
    ) public pure returns (PortfolioState memory) {
        portfolioState.addAsset(
            currencyId,
            maturity,
            assetType,
            notional,
            isNewHint
        );

        return portfolioState;
    }

    function getAccountContext(address account) external view returns (AccountStorage memory) {
        return AccountContextHandler.getAccountContext(account);
    }

    function storeAssets(
        address account,
        PortfolioState memory portfolioState
    ) public returns (bool, bytes32, uint8, uint) {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        (
            bool hasDebt,
            bytes32 activeCurrencies,
            uint8 assetArrayLength,
            uint nextMaturingAsset
        ) = portfolioState.storeAssets(account);
        accountContext.setAccountContext(account);

        return (hasDebt, activeCurrencies, assetArrayLength, nextMaturingAsset);
    }

    function deleteAsset(
        PortfolioState memory portfolioState,
        uint index
    ) public pure returns (PortfolioState memory) {
        portfolioState.deleteAsset(index);

        return portfolioState;
    }

    function getEncodedId(
        PortfolioAsset memory asset
    ) public pure returns (uint) {
        return PortfolioHandler.getEncodedId(asset);
    }

    function buildPortfolioState(
        address account,
        uint newAssetsHint
    ) public view returns (PortfolioState memory) {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);

        return PortfolioHandler.buildPortfolioState(
            account,
            accountContext.assetArrayLength,
            newAssetsHint
        );
    }

}