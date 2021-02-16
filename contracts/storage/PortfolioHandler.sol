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
                require(
                    portfolioState.storedAssets[i].storageState != AssetStorageState.Delete,
                    "P: storage index"
                );

                int newNotional = portfolioState.storedAssets[i].notional.add(notional);
                // Liquidity tokens cannot be reduced below zero.
                if (AssetHandler.isLiquidityToken(assetType)) {
                    require(newNotional >= 0, "P: negative token balance");
                }

                require(
                    /* int88 == type(AssetStorage.notional) */
                    newNotional >= type(int88).min && newNotional <= type(int88).max,
                    "P: notional overflow"
                );

                portfolioState.storedAssets[i].notional = newNotional;
                portfolioState.storedAssets[i].storageState = AssetStorageState.Update;

                return;
            }
        }

        // Cannot remove liquidity that the portfolio does not have
        if (AssetHandler.isLiquidityToken(assetType)) {
            require(notional >= 0, "P: negative token balance");
        }

        require(
            /* int88 == type(AssetStorage.notional) */
            notional >= type(int88).min && notional <= type(int88).max,
            "P: notional overflow"
        );

        // Need to provision a new array at this point
        if (portfolioState.lastNewAssetIndex == portfolioState.newAssets.length) {
            portfolioState.newAssets = extendNewAssetArray(portfolioState.newAssets);
        }

        // Otherwise add to the new assets array. It should not be possible to add matching assets in a single transaction, we will
        // check this again when we write to storage.
        portfolioState.newAssets[portfolioState.lastNewAssetIndex] = PortfolioAsset({
            currencyId: currencyId,
            maturity: maturity,
            assetType: assetType,
            notional: notional,
            storageState: AssetStorageState.NoChange
        });
        portfolioState.lastNewAssetIndex += 1;
    }

    /**
     * @notice Takes a portfolio state and writes it to storage
     */
    function storeAssets(
        PortfolioState memory portfolioState,
        AssetStorage[] storage assetStoragePointer
    ) internal {
        uint assetStorageLength = portfolioState.storedAssets.length;
        PortfolioAsset memory tmpM;

        // First delete assets from asset storage to maintain asset storage indexes
        for (uint i; i < assetStorageLength; i++) {
            if (portfolioState.storedAssets[i].storageState == AssetStorageState.Delete
                // If notional = 0 then the asset is net off, delete it
                || portfolioState.storedAssets[i].notional == 0) {

                // Swap all the assets to the end of the array
                // Storage Read / write
                AssetStorage storage tmpS = assetStoragePointer[i];
                assetStoragePointer[i] = assetStoragePointer[assetStorageLength - 1];
                assetStoragePointer[assetStorageLength - 1] = tmpS;
                assetStoragePointer.pop();

                // Mirror the swap in memory
                tmpM = portfolioState.storedAssets[i];
                portfolioState.storedAssets[i] = portfolioState.storedAssets[assetStorageLength - 1];
                portfolioState.storedAssets[assetStorageLength - 1] = tmpM;

                assetStorageLength = assetStorageLength - 1;
                i = i - 1;
            }
        }

        // Next, update values that have changed
        for (uint i; i < assetStorageLength; i++) {
            if (portfolioState.storedAssets[i].storageState != AssetStorageState.Update) continue;

            require(
                portfolioState.storedAssets[i].notional <= type(int88).max
                    && portfolioState.storedAssets[i].notional >= type(int88).min, 
                "P: notional overflow"
            );

            // Storage Write
            assetStoragePointer[i].notional = int88(portfolioState.storedAssets[i].notional);
        }

        // Finally, add new assets
        // TODO: add max assets parameter
        for (uint i; i < portfolioState.newAssets.length; i++) {
            uint16 currencyId = uint16(portfolioState.newAssets[i].currencyId);
            uint8 assetType = uint8(portfolioState.newAssets[i].assetType);
            uint40 maturity = uint40(portfolioState.newAssets[i].maturity);
            int88 notional = int88(portfolioState.newAssets[i].notional);

            // Storage Write
            assetStoragePointer.push(AssetStorage({
                currencyId: currencyId,
                assetType: assetType,
                maturity: maturity,
                notional: notional
            }));
        }
    }

    /**
     * @notice Deletes an asset, should only be used during settlement
     */
    function deleteAsset(
        PortfolioState memory portfolioState,
        uint index
    ) internal pure {
        require(index < portfolioState.storedAssets.length, "P: settle index bounds");
        require(portfolioState.storedAssetLength > 0, "P: stored asset bounds");
        
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
        // TODO: make these uints and save the conversion here
        int i = left;
        int j = right;

        uint pivot = getEncodedId(assets[indexes[uint(left + (right - left) / 2)]]);
        while (i <= j) {
            while (getEncodedId(assets[indexes[uint(i)]]) < pivot) i++;
            while (pivot < getEncodedId(assets[indexes[uint(j)]])) j--;
            if (i <= j) {
                // Swap positions
                (indexes[uint(i)], indexes[uint(j)]) = (indexes[uint(j)], indexes[uint(i)]);
                i++;
                j--;
            }
        }

        if (left < j) _quickSort(assets, indexes, left, j);
        if (i < right) _quickSort(assets, indexes, i, right);
    }

    /**
     * @notice Returns an single array that contains the new and stored assets merged and sorted by currency
     * id and maturity.
     */
    function getMergedArray(
        PortfolioState memory portfolioState
    ) internal pure returns (PortfolioAsset[] memory) {
        // Last new asset index is equal to the number of new assets inserted in the array
        uint totalAssets = portfolioState.storedAssetLength + portfolioState.lastNewAssetIndex;
        PortfolioAsset[] memory mergedAssets = new PortfolioAsset[](totalAssets);

        uint storedAssetsIndex;
        uint newAssetsIndex;
        uint mergedAssetsIndex;
        while (storedAssetsIndex < portfolioState.storedAssets.length
               || newAssetsIndex < portfolioState.newAssets.length) {
            PortfolioAsset memory storedAsset;
            PortfolioAsset memory newAsset;

            if (storedAssetsIndex < portfolioState.sortedIndex.length) {
                storedAsset = portfolioState.storedAssets[portfolioState.sortedIndex[storedAssetsIndex]];
            }

            if (newAssetsIndex < portfolioState.newAssets.length) {
                newAsset = portfolioState.newAssets[newAssetsIndex];
            }

            if (storedAsset.assetType == 0) {
                // Stored asset is zero because there are no more stored assets so we will just insert the
                // new asset.
                mergedAssets[mergedAssetsIndex] = newAsset;
                newAssetsIndex += 1;
                mergedAssetsIndex += 1;
            } else if (newAsset.assetType == 0) {
                // If new asset is zero then there are no more, we insert the stored asset as long as it is not
                // a delete
                if (storedAsset.storageState != AssetStorageState.Delete) {
                    mergedAssets[mergedAssetsIndex] = storedAsset;
                    mergedAssetsIndex += 1;
                }
                // Continue to increment the index either way to get past a deleted asset.
                storedAssetsIndex += 1;
            } else if (getEncodedId(newAsset) < getEncodedId(storedAsset)) {
                // Compare the assets and insert the one with a lower valued id. These should never be equal!
                mergedAssets[mergedAssetsIndex] = newAsset;
                newAssetsIndex += 1;
                mergedAssetsIndex += 1;
            } else {
                if (storedAsset.storageState != AssetStorageState.Delete) {
                    mergedAssets[mergedAssetsIndex] = storedAsset;
                    mergedAssetsIndex += 1;
                }
                storedAssetsIndex += 1;
            }
        }

        return mergedAssets;
    }

    /**
     * @notice Builds a portfolio array from storage. The new assets hint parameter will
     * be used to provision a new array for the new assets. This will increase gas efficiency
     * so that we don't have to make copies when we extend the array.
     */
    function buildPortfolioState(
        address account,
        uint newAssetsHint
    ) internal view returns (PortfolioState memory) {
        // TODO: change this to a string
        bytes32 slot = keccak256(abi.encode(account, 7));
        uint length;
        assembly { length := sload(slot) }
        PortfolioAsset[] memory result = new PortfolioAsset[](length);
        // For an array in a mapping, the slot is rehashed for the offset.
        uint arraySlot = uint(keccak256(abi.encode(slot)));

        for (uint i; i < length; i++) {
            bytes32 data;
            assembly { data := sload(arraySlot) }

            result[i].currencyId = uint(uint16(uint(data)));
            result[i].maturity = uint(uint40(uint(data >> 16)));
            result[i].assetType = uint(uint8(uint(data >> 56)));
            result[i].notional = int(int88(uint(data >> 64)));
            arraySlot = arraySlot + 1;
        }

        return PortfolioState({
            storedAssets: result,
            newAssets: new PortfolioAsset[](newAssetsHint),
            lastNewAssetIndex: 0,
            storedAssetLength: result.length,
            // This index is initiated if required during settlement or FC
            sortedIndex: new uint[](0)
        });
    }

}
