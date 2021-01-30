// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageLayoutV1.sol";
import "../math/SafeInt256.sol";

enum AssetStorageState {
    NoChange,
    Update,
    Delete
}

struct PortfolioAsset {
    // Asset currency id
    uint currencyId;
    // Asset type, liquidity or fCash
    uint assetType;
    uint maturity;
    // fCash amount or liquidity token amount
    int notional;
    // The state of the asset for when it is written to storage
    AssetStorageState storageState;
}

// Track new assets separately so we don't have to copy the PortfolioAsset
// array every time we extend it.
struct NewAsset {
    uint currencyId;
    uint assetType;
    uint maturity;
    int notional;
}

struct PortfolioState {
    PortfolioAsset[] storedAssets;
    NewAsset[] newAssets;
    uint lastNewAssetIndex;
    // Holds the length of stored assets after account for deleted assets
    uint storedAssetLength;
}

/**
 * @notice Handles the management of an array of assets including reading from storage, inserting
 * updating, deleting and writing back to storage.
 */
library PortfolioHandler {
    using SafeInt256 for int;

    function extendNewAssetArray(
        NewAsset[] memory newAssets
    ) internal pure returns (NewAsset[] memory) {
        NewAsset[] memory extendedArray = new NewAsset[](newAssets.length + 1);
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
        uint assetType,
        uint maturity,
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
                if (assetType == 2 /* LIQUIDITY_TOKEN_ASSET_TYPE */) {
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
        if (assetType == 2 /* LIQUIDITY_TOKEN_ASSET_TYPE */) {
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
        portfolioState.newAssets[portfolioState.lastNewAssetIndex] = NewAsset({
            currencyId: currencyId,
            assetType: assetType,
            maturity: maturity,
            notional: notional
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
        portfolioState.storedAssetLength = portfolioState.storedAssetLength - 1;
    }


    /**
     * @notice Builds a portfolio array from storage. The new assets hint parameter will
     * be used to provision a new array for the new assets. This will increase gas efficiency
     * so that we don't have to make copies when we extend the array.
     */
    function buildPortfolioState(
        AssetStorage[] storage assetStoragePointer,
        uint newAssetsHint
    ) internal view returns (PortfolioState memory) {
        // Storage Read
        uint length = assetStoragePointer.length;
        PortfolioAsset[] memory result = new PortfolioAsset[](length);
        AssetStorage memory tmp;

        for (uint i; i < length; i++) {
            // TODO: check if this is necessary
            // Storage Read
            tmp = assetStoragePointer[i];
            result[i] = PortfolioAsset({
                currencyId: tmp.currencyId,
                assetType: tmp.assetType,
                maturity: tmp.maturity,
                notional: tmp.notional,
                storageState: AssetStorageState.NoChange
            });
        }

        return PortfolioState({
            storedAssets: result,
            newAssets: new NewAsset[](newAssetsHint),
            lastNewAssetIndex: 0,
            storedAssetLength: result.length
        });
    }

}

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

    function addAsset(
        PortfolioState memory portfolioState,
        uint currencyId,
        uint assetType,
        uint maturity,
        int notional,
        bool isNewHint
    ) public pure returns (PortfolioState memory) {
        portfolioState.addAsset(
            currencyId,
            assetType,
            maturity,
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

    function buildPortfolioState(
        address account,
        uint newAssetsHint
    ) public view returns (PortfolioState memory) {
        AssetStorage[] storage pointer = assetArrayMapping[account];

        return PortfolioHandler.buildPortfolioState(
            pointer,
            newAssetsHint
        );
    }

}