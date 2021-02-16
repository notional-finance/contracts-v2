// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/PortfolioHandler.sol";
import "../storage/StorageLayoutV1.sol";

contract MockPortfolioHandler is StorageLayoutV1 {
    using PortfolioHandler for PortfolioState;

    function setAssetArray(
        address account,
        AssetStorage[] memory a
    ) external {
        // Clear array
        delete assetArrayMapping[account];

        AssetStorage[] storage s = assetArrayMapping[account];
        for (uint i; i < a.length; i++) {
            s.push(a[i]);
        }
    }

    function getAssetArray(address account) external view returns (AssetStorage[] memory) {
        return assetArrayMapping[account];
    }

    function getMergedArray(
        PortfolioState memory portfolioState
    ) public pure returns (PortfolioAsset[] memory) {
        portfolioState.calculateSortedIndex();
        return portfolioState.getMergedArray();
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

    function storeAssets(
        address account,
        PortfolioState memory portfolioState
    ) public {
        AssetStorage[] storage pointer = assetArrayMapping[account];
        portfolioState.storeAssets(pointer);
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

    function calculateSortedIndex(
        PortfolioState memory portfolioState
    ) public pure returns (uint[] memory) {
        portfolioState.calculateSortedIndex();
        return portfolioState.sortedIndex;
    }

    function buildPortfolioState(
        address account,
        uint newAssetsHint
    ) public view returns (PortfolioState memory) {
        return PortfolioHandler.buildPortfolioState(
            account,
            newAssetsHint
        );
    }

}