// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageLayoutV1.sol";
import "../common/CashGroup.sol";
import "../common/AssetHandler.sol";
import "../math/SafeInt256.sol";

struct PortfolioState {
    PortfolioAsset[] storedAssets;
    PortfolioAsset[] newAssets;
    uint lastNewAssetIndex;
    // Holds the length of stored assets after accounting for deleted assets
    uint storedAssetLength;
}

/**
 * @notice Handles the management of an array of assets including reading from storage, inserting
 * updating, deleting and writing back to storage.
 */
library PortfolioHandler {
    using SafeInt256 for int;
    using AssetHandler for PortfolioAsset;

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
        address account
    ) internal returns (bool, bytes32, uint8, uint40) {
        uint initialSlot = uint(keccak256(abi.encode(account, "account.array")));
        bool hasDebt;
        bytes32 portfolioActiveCurrencies;
        uint nextSettleTime;

        // Mark any zero notional assets as deleted
        for (uint i; i < portfolioState.storedAssets.length; i++) {
            if (portfolioState.storedAssets[i].storageState != AssetStorageState.Delete &&
                portfolioState.storedAssets[i].notional == 0) {
                deleteAsset(portfolioState, i);
            }
        }

        // First delete assets from asset storage to maintain asset storage indexes
        for (uint i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.storageState == AssetStorageState.Delete) {
                // Storage Read / write
                uint currentSlot = asset.storageSlot;
                assembly { sstore(currentSlot, 0x00) }
                continue;
            } 
            
            if (portfolioState.storedAssets[i].storageState == AssetStorageState.Update) {
                uint currentSlot = asset.storageSlot;
                bytes32 encodedAsset = encodeAssetToBytes(portfolioState.storedAssets[i]);
                assembly { sstore(currentSlot, encodedAsset) }
            }

            // Update account context parameters for active assets
            if (nextSettleTime == 0 || nextSettleTime > asset.getSettlementDate()) {
                nextSettleTime = asset.getSettlementDate();
            }
            hasDebt = asset.notional < 0 || hasDebt;
            portfolioActiveCurrencies = (portfolioActiveCurrencies >> 16) | (bytes32(asset.currencyId) << 240);
        }

        // Add new assets
        uint assetStorageLength = portfolioState.storedAssetLength;
        for (uint i; i < portfolioState.newAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.newAssets[i];
            if (asset.notional == 0) continue;
            bytes32 encodedAsset = encodeAssetToBytes(portfolioState.newAssets[i]);
            uint newAssetSlot = initialSlot + assetStorageLength;

            if (nextSettleTime == 0 || nextSettleTime > asset.getSettlementDate()) {
                nextSettleTime = asset.getSettlementDate();
            }
            hasDebt = asset.notional < 0 || hasDebt;
            portfolioActiveCurrencies = (portfolioActiveCurrencies >> 16) | (bytes32(asset.currencyId) << 240);

            assembly { sstore(newAssetSlot, encodedAsset) }
            assetStorageLength += 1;
        }

        // TODO: allow liquidation to skip this check
        require(assetStorageLength <= CashGroup.MAX_TRADED_MARKET_INDEX); // dev: max assets allowed

        return (
            hasDebt,
            portfolioActiveCurrencies,
            uint8(assetStorageLength),
            uint40(nextSettleTime)
        );
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
        
        portfolioState.storedAssetLength -= 1;

        uint maxActiveSlotIndex;
        uint maxActiveSlot;
        for (uint i; i < portfolioState.storedAssets.length; i++) {
            if (portfolioState.storedAssets[i].storageSlot > maxActiveSlot
                && portfolioState.storedAssets[i].storageState != AssetStorageState.Delete) {
                maxActiveSlot = portfolioState.storedAssets[i].storageSlot;
                maxActiveSlotIndex = i;
            }
        }

        if (index == maxActiveSlotIndex) {
            portfolioState.storedAssets[index].storageState = AssetStorageState.Delete;
            return;
        }

        // Swap the storage slots of the deleted asset with the last non-deleted asset in the array. Mark them accordingly
        // so that when we call store assets they will be updated approporiately
        (
            portfolioState.storedAssets[maxActiveSlotIndex].storageSlot,
            portfolioState.storedAssets[index].storageSlot
        ) = (
            portfolioState.storedAssets[index].storageSlot,
            portfolioState.storedAssets[maxActiveSlotIndex].storageSlot
        );
        portfolioState.storedAssets[maxActiveSlotIndex].storageState = AssetStorageState.Update;
        portfolioState.storedAssets[index].storageState = AssetStorageState.Delete;
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
        require(asset.notional >= type(int88).min && asset.notional <= type(int88).max); // dev: encode asset notional overflow

        return (
            bytes32(asset.currencyId)      |
            bytes32(asset.maturity)  << 16 |
            bytes32(asset.assetType) << 56 |
            bytes32(asset.notional) << 64
        );
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
            assets[i].storageSlot = slot;
            slot = slot + 1;
        }

        return assets;
    }

    function getSortedPortfolio(
        address account,
        uint8 assetArrayLength
    ) internal view returns (PortfolioAsset[] memory) {
        PortfolioAsset[] memory assets = loadAssetArray(account, assetArrayLength);

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

        state.storedAssets = getSortedPortfolio(account, assetArrayLength);
        state.storedAssetLength = assetArrayLength;
        state.newAssets = new PortfolioAsset[](newAssetsHint);

        return state;
    }

}
