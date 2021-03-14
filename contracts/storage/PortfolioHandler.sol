// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageLayoutV1.sol";
import "../common/AssetHandler.sol";
import "../math/SafeInt256.sol";

struct PortfolioState {
    PortfolioAsset[] storedAssets;
    PortfolioAsset[] newAssets;
    uint lastNewAssetIndex;
    // Holds the length of stored assets after account for deleted assets
    uint storedAssetLength;
    uint[] sortedIndex;
}

/**
 * @notice Handles the management of an array of assets including reading from storage, inserting
 * updating, deleting and writing back to storage.
 */
library PortfolioHandler {
    using SafeInt256 for int;

    function extendNewAssetArray(
        PortfolioAsset[] memory newAssets
    ) internal pure returns (PortfolioAsset[] memory) {
        PortfolioAsset[] memory extendedArray = new PortfolioAsset[](newAssets.length + 1);
        for (uint i; i < newAssets.length; i++) {
            extendedArray[i] = newAssets[i];
        }

        return extendedArray;
    }

    /**
     * @notice Adds or updates a new asset in memory
     */
    function addAsset(
        PortfolioState memory portfolioState,
        uint currencyId,
        uint maturity,
        uint assetType,
        int notional,
        bool isNewHint
    ) internal pure {
        if (!isNewHint || portfolioState.storedAssets.length == 0) {
            // If the stored asset exists then we add notional to the position
            for (uint i; i < portfolioState.storedAssets.length; i++) {
                if (portfolioState.storedAssets[i].assetType != assetType) continue;
                if (portfolioState.storedAssets[i].currencyId != currencyId) continue;
                if (portfolioState.storedAssets[i].maturity != maturity) continue;

                // If the storage index is -1 this is because it's been deleted from settlement. We cannot
                // add fcash that has been settled.
                require(portfolioState.storedAssets[i].storageState != AssetStorageState.Delete); // dev: portfolio handler deleted storage

                int newNotional = portfolioState.storedAssets[i].notional.add(notional);
                // Liquidity tokens cannot be reduced below zero.
                if (AssetHandler.isLiquidityToken(assetType)) {
                    require(newNotional >= 0); // dev: portfolio handler negative liquidity token balance
                }

                require(newNotional >= type(int88).min && newNotional <= type(int88).max); // dev: portfolio handler notional overflow

                portfolioState.storedAssets[i].notional = newNotional;
                portfolioState.storedAssets[i].storageState = AssetStorageState.Update;

                return;
            }
        }

        // Cannot remove liquidity that the portfolio does not have
        if (AssetHandler.isLiquidityToken(assetType)) {
            require(notional >= 0); // dev: portfolio handler negative liquidity token balance
        }
        require(notional >= type(int88).min && notional <= type(int88).max); // dev: portfolio handler notional overflow

        // Need to provision a new array at this point
        if (portfolioState.lastNewAssetIndex == portfolioState.newAssets.length) {
            portfolioState.newAssets = extendNewAssetArray(portfolioState.newAssets);
        }

        // Otherwise add to the new assets array. It should not be possible to add matching assets in a single transaction, we will
        // check this again when we write to storage.
        portfolioState.newAssets[portfolioState.lastNewAssetIndex].currencyId = currencyId;
        portfolioState.newAssets[portfolioState.lastNewAssetIndex].maturity = maturity;
        portfolioState.newAssets[portfolioState.lastNewAssetIndex].assetType = assetType;
        portfolioState.newAssets[portfolioState.lastNewAssetIndex].notional = notional;
        portfolioState.newAssets[portfolioState.lastNewAssetIndex].storageState = AssetStorageState.NoChange;
        portfolioState.lastNewAssetIndex += 1;
    }

    /**
     * @notice Takes a portfolio state and writes it to storage
     */
    function storeAssets(
        PortfolioState memory portfolioState,
        address account,
        AccountStorage memory accountContext
    ) internal {
        uint assetStorageLength = portfolioState.storedAssets.length;
        uint initialSlot = uint(keccak256(abi.encode(account, "account.array")));
        // todo: set nextMaturingAsset, activeCurrencies, hasDebt

        // First delete assets from asset storage to maintain asset storage indexes
        for (uint i; i < assetStorageLength; i++) {
            if (portfolioState.storedAssets[i].storageState == AssetStorageState.Delete
                // If notional = 0 then the asset is net off, delete it
                || portfolioState.storedAssets[i].notional == 0) {

                // Storage Read / write
                bytes32 lastAsset;
                uint lastAssetSlot = initialSlot + assetStorageLength - 1;
                uint currentSlot = initialSlot + i;
                assembly { lastAsset := sload(lastAssetSlot) }
                assembly { sstore(currentSlot, lastAsset) }
                // Delete the last asset, it is now stored in currentSlot
                assembly { sstore(lastAssetSlot, 0x00) }

                // Mirror the swap in memory
                (portfolioState.storedAssets[assetStorageLength - 1], portfolioState.storedAssets[i]) = 
                    (portfolioState.storedAssets[i], portfolioState.storedAssets[assetStorageLength - 1]);

                assetStorageLength -= 1;
                i -= 1;
            }
        }

        // Next, update values that have changed
        for (uint i; i < assetStorageLength; i++) {
            if (portfolioState.storedAssets[i].storageState != AssetStorageState.Update) continue;

            uint currentSlot = initialSlot + i;
            bytes32 encodedAsset = encodeAssetToBytes(portfolioState.storedAssets[i]);
            assembly { sstore(currentSlot, encodedAsset) }
        }

        uint newAssetSlot = initialSlot + assetStorageLength;
        // Finally, add new assets
        for (uint i; i < portfolioState.newAssets.length; i++) {
            if (portfolioState.newAssets[i].notional == 0) continue;
            bytes32 encodedAsset = encodeAssetToBytes(portfolioState.storedAssets[i]);
            assembly { sstore(newAssetSlot, encodedAsset) }
            newAssetSlot += 1;
        }

        // Very unlikely potential for overflow here...
        accountContext.assetArrayLength = uint8(newAssetSlot - initialSlot);
    }

    /**
     * @notice Deletes an asset, should only be used during settlement
     */
    function deleteAsset(
        PortfolioState memory portfolioState,
        uint index
    ) internal pure {
        require(index < portfolioState.storedAssets.length); // dev: stored assets bounds
        require(portfolioState.storedAssetLength > 0); // dev: stored assets length is zero
        
        portfolioState.storedAssets[index].storageState = AssetStorageState.Delete;
        portfolioState.storedAssetLength -= 1;
    }

    /**
     * @dev These ids determine the sort order of assets
     */
    function getEncodedId(
        PortfolioAsset memory asset
    ) internal pure returns (uint) {
        return uint(
            bytes32(asset.currencyId) << 48 |
            bytes32(asset.maturity) << 8 |
            bytes32(asset.assetType)
        );
    }

    /**
     * @dev These ids determine the sort order of assets
     */
    function encodeAssetToBytes(
        PortfolioAsset memory asset
    ) internal pure returns (bytes32) {
        require(asset.currencyId > 0 && asset.currencyId <= type(uint16).max); // dev: encode asset currency id overflow
        require(asset.maturity > 0 && asset.maturity <= type(uint40).max); // dev: encode asset maturity overflow
        require(asset.assetType > 0 && asset.assetType <= AssetHandler.LIQUIDITY_TOKEN_INDEX9); // dev: encode asset type invalid
        require(asset.notional >= type(int88).min && asset.notional <= type(uint88).max); // dev: encode asset notional overflow

        return (
            bytes32(asset.currencyId)      |
            bytes32(asset.maturity)  << 16 |
            bytes32(asset.assetType) << 56 |
            bytes32(asset.notional) << 64
        );
    }

    /**
     * @notice Calculates an index where portfolioState.storedAssets are sorted by
     * cash group and maturity
     */
    function calculateSortedIndex(
        PortfolioState memory portfolioState
    ) internal pure {
        // These are base cases that don't require looping
        if (portfolioState.storedAssets.length == 0) return;
        if (portfolioState.storedAssets.length == 1) {
            portfolioState.sortedIndex = new uint[](1);
            return;
        }

        if (portfolioState.storedAssets.length == 2) {
            uint[] memory result = new uint[](2);
            uint firstKey = getEncodedId(portfolioState.storedAssets[0]);
            uint secondKey = getEncodedId(portfolioState.storedAssets[1]);

            if (firstKey < secondKey) result[1] = 1;
            else result[0] = 1;

            portfolioState.sortedIndex = result;
            return;
        }

        uint[] memory indexes = new uint[](portfolioState.storedAssets.length);
        for (uint i; i < indexes.length; i++) indexes[i] = i;

        _quickSort(portfolioState.storedAssets, indexes, int(0), int(indexes.length) - 1);
        portfolioState.sortedIndex = indexes;
    }

    /**
     * @dev Leaves the assets array in place and sorts the indexes.
     */
    function _quickSort(
        PortfolioAsset[] memory assets,
        uint[] memory indexes,
        int left,
        int right
    ) internal pure {
        if (left == right) return;
        int i = left;
        int j = right;

        uint pivot = getEncodedId(assets[indexes[uint(left + (right - left) / 2)]]);
        while (i <= j) {
            while (getEncodedId(assets[indexes[uint(i)]]) < pivot) i++;
            while (pivot < getEncodedId(assets[indexes[uint(j)]])) j--;
            if (i <= j) {
                (indexes[uint(i)], indexes[uint(j)]) = (indexes[uint(j)], indexes[uint(i)]);
                i++;
                j--;
            }
        }

        if (left < j) _quickSort(assets, indexes, left, j);
        if (i < right) _quickSort(assets, indexes, i, right);
    }

    function _quickSortInPlace(
        PortfolioAsset[] memory assets,
        int left,
        int right
    ) internal pure {
        if (left == right) return;
        int i = left;
        int j = right;

        uint pivot = getEncodedId(assets[uint(left + (right - left) / 2)]);
        while (i <= j) {
            while (getEncodedId(assets[uint(i)]) < pivot) i++;
            while (pivot < getEncodedId(assets[uint(j)])) j--;
            if (i <= j) {
                (assets[uint(i)], assets[uint(j)]) = (assets[uint(j)], assets[uint(i)]);
                i++;
                j--;
            }
        }

        if (left < j) _quickSortInPlace(assets, left, j);
        if (i < right) _quickSortInPlace(assets, i, right);
    }

    function loadAssetArray(
        address account,
        uint8 length
    ) private view returns (PortfolioAsset[] memory) {
        PortfolioAsset[] memory assets = new PortfolioAsset[](length);
        uint slot = uint(keccak256(abi.encode(account, "account.array")));

        for (uint i; i < length; i++) {
            bytes32 data;
            assembly { data := sload(slot) }

            assets[i].currencyId = uint(uint16(uint(data)));
            assets[i].maturity = uint(uint40(uint(data >> 16)));
            assets[i].assetType = uint(uint8(uint(data >> 56)));
            assets[i].notional = int(int88(uint(data >> 64)));
            slot = slot + 1;
        }

        return assets;
    }

    function getSortedPortfolio(
        address account,
        AccountStorage memory accountContext
    ) internal view returns (PortfolioAsset[] memory) {
        PortfolioAsset[] memory assets = loadAssetArray(account, accountContext.assetArrayLength);

        if (assets.length <= 1) return assets;

        _quickSortInPlace(assets, 0, int(assets.length) - 1);
        return assets;
    }

    /**
     * @notice Builds a portfolio array from storage. The new assets hint parameter will
     * be used to provision a new array for the new assets. This will increase gas efficiency
     * so that we don't have to make copies when we extend the array.
     */
    function buildPortfolioState(
        address account,
        uint8 assetArrayLength,
        uint newAssetsHint
    ) internal view returns (PortfolioState memory) {
        PortfolioState memory state;
        if (assetArrayLength == 0) return state;

        state.storedAssets = loadAssetArray(account, assetArrayLength);
        state.storedAssetLength = assetArrayLength;
        state.newAssets = new PortfolioAsset[](newAssetsHint);

        return state;
    }

}
