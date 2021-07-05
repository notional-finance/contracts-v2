// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/portfolio/PortfolioHandler.sol";

library PortfolioHandlerHarness {

    function addMultipleAssets(PortfolioState memory portfolioState, PortfolioAsset[] memory assets)
        internal
        pure
    {
        PortfolioHandler.addMultipleAssets(portfolioState, assets);
    }

    function addAsset(
        PortfolioState memory portfolioState,
        uint256 currencyId,
        uint256 maturity,
        uint256 assetType,
        int256 notional,
        bool isNewHint
    ) internal pure {
        PortfolioHandler.addAsset(portfolioState, currencyId, maturity, assetType, notional, isNewHint);
    }

    function storeAssets(PortfolioState memory portfolioState, address account)
        internal
        returns (
            bool,
            bytes32,
            uint8,
            uint40
        )
    {
        uint256 slot =
            uint256(keccak256(abi.encode(account, Constants.PORTFOLIO_ARRAY_STORAGE_OFFSET)));
        bool hasDebt;
        bytes32 portfolioActiveCurrencies;
        uint256 nextSettleTime;

        for (uint256 i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.storageState == AssetStorageState.Delete || asset.notional == 0) {
                continue;
            }

            (hasDebt, portfolioActiveCurrencies, nextSettleTime) = PortfolioHandler._updatePortfolioContext(
                asset,
                hasDebt,
                portfolioActiveCurrencies,
                nextSettleTime
            );

            bytes32 encodedAsset = PortfolioHandler._encodeAssetToBytes(asset);
            assembly {
                sstore(slot, encodedAsset)
            }
            slot = slot + 1;
        }

        for (uint256 i; i < portfolioState.newAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.newAssets[i];
            if (asset.notional == 0) continue;

            (hasDebt, portfolioActiveCurrencies, nextSettleTime) = PortfolioHandler._updatePortfolioContext(
                asset,
                hasDebt,
                portfolioActiveCurrencies,
                nextSettleTime
            );

            bytes32 encodedAsset = PortfolioHandler._encodeAssetToBytes(asset);
            assembly {
                sstore(slot, encodedAsset)
            }
            slot = slot + 1;
        }
    }

    function deleteAsset(PortfolioState memory portfolioState, uint256 index) internal pure {
        require(index < portfolioState.storedAssets.length); // dev: stored assets bounds
        require(portfolioState.storedAssetLength > 0); // dev: stored assets length is zero

        portfolioState.storedAssetLength -= 1;
        portfolioState.storedAssets[index].storageState = AssetStorageState.Delete;
    }

    function getSortedPortfolio(address account, uint8 assetArrayLength)
        internal
        view
        returns (PortfolioAsset[] memory)
    {
        PortfolioAsset[] memory assets = PortfolioHandler._loadAssetArray(account, assetArrayLength);
        // No sorting required for length of 1
        if (assets.length <= 1) return assets;

        return assets;
    }

    function buildPortfolioState(
        address account,
        uint8 assetArrayLength,
        uint256 newAssetsHint
    ) internal view returns (PortfolioState memory) {
        PortfolioState memory state;
        if (assetArrayLength == 0) return state;

        state.storedAssets = getSortedPortfolio(account, assetArrayLength);
        state.storedAssetLength = assetArrayLength;
        state.newAssets = new PortfolioAsset[](newAssetsHint);

        return state;
    }
}