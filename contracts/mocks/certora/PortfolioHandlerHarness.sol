// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/portfolio/PortfolioHandler.sol";

/**
 * Simplified portfolio handler for Certora verification. Cannot handle more assets than
 * DEFAULT_NUM_ASSETS and will always load that number of assets from storage. Will merge
 * matching assets but if assets do not match then will append to the first empty slot. Stores
 * all assets by overwriting all slots.
 */
library PortfolioHandlerHarness {
    using SafeInt256 for int256;

    uint8 private constant DEFAULT_NUM_ASSETS = 4;

    function addMultipleAssets(PortfolioState memory portfolioState, PortfolioAsset[] memory assets)
        internal
        pure
    {
        // Calls simplified add asset instead
        for (uint256 i; i < assets.length; i++) {
            if (assets[i].notional == 0) continue;

            addAsset(
                portfolioState,
                assets[i].currencyId,
                assets[i].maturity,
                assets[i].assetType,
                assets[i].notional,
                false
            );
        }
    }

    function addAsset(
        PortfolioState memory portfolioState,
        uint256 currencyId,
        uint256 maturity,
        uint256 assetType,
        int256 notional,
        bool isNewHint
    ) internal pure {
        PortfolioAsset[] memory assetArray = portfolioState.storedAssets;
        uint256 i = 0;

        for (; i < assetArray.length; i++) {
            if (assetArray[i].assetType == 0) break;
            if (assetArray[i].assetType != assetType) continue;
            if (assetArray[i].currencyId != currencyId) continue;
            if (assetArray[i].maturity != maturity) continue;

            // If the storage index is -1 this is because it's been deleted from settlement. We cannot
            // add fcash that has been settled.
            require(assetArray[i].storageState != AssetStorageState.Delete); // dev: portfolio handler deleted storage

            int256 newNotional = assetArray[i].notional.add(notional);
            // Liquidity tokens cannot be reduced below zero.
            if (AssetHandler.isLiquidityToken(assetType)) {
                require(newNotional >= 0); // dev: portfolio handler negative liquidity token balance
            }

            require(newNotional >= type(int88).min && newNotional <= type(int88).max); // dev: portfolio handler notional overflow

            assetArray[i].notional = newNotional;
            assetArray[i].storageState = AssetStorageState.Update;

            return;
        }

        // Append to first empty slot in the array
        assetArray[i].currencyId = currencyId;
        assetArray[i].maturity = maturity;
        assetArray[i].notional = notional;
        assetArray[i].storageState = AssetStorageState.Update;
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

        // In the simplified version we assume that new assets is unused
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
        // Just provision an array of some arbitrary length and ensure that assets are less than this
        return PortfolioHandler._loadAssetArray(account, DEFAULT_NUM_ASSETS);
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