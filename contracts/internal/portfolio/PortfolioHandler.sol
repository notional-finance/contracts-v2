// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    PortfolioState,
    PortfolioAsset,
    PortfolioAssetStorage,
    AssetStorageState
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {TransferAssets} from "./TransferAssets.sol";
import {AssetHandler} from "../valuation/AssetHandler.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

/// @notice Handles the management of an array of assets including reading from storage, inserting
/// updating, deleting and writing back to storage.
library PortfolioHandler {
    using SafeInt256 for int256;
    using AssetHandler for PortfolioAsset;

    // Mirror of LibStorage.MAX_PORTFOLIO_ASSETS
    uint256 private constant MAX_PORTFOLIO_ASSETS = 8;

    /// @notice Primarily used by the TransferAssets library
    function addMultipleAssets(PortfolioState memory portfolioState, PortfolioAsset[] memory assets)
        internal
        pure
    {
        for (uint256 i = 0; i < assets.length; i++) {
            PortfolioAsset memory asset = assets[i];
            if (asset.notional == 0) continue;

            addAsset(
                portfolioState,
                asset.currencyId,
                asset.maturity,
                asset.assetType,
                asset.notional
            );
        }
    }

    function _mergeAssetIntoArray(
        PortfolioAsset[] memory assetArray,
        uint16 currencyId,
        uint256 maturity,
        uint256 assetType,
        int256 notional
    ) private pure returns (bool) {
        for (uint256 i = 0; i < assetArray.length; i++) {
            PortfolioAsset memory asset = assetArray[i];
            if (
                asset.assetType != assetType ||
                asset.currencyId != currencyId ||
                asset.maturity != maturity
            ) continue;

            // Either of these storage states mean that some error in logic has occurred, we cannot
            // store this portfolio
            require(
                asset.storageState != AssetStorageState.Delete &&
                asset.storageState != AssetStorageState.RevertIfStored
            ); // dev: portfolio handler deleted storage

            int256 newNotional = asset.notional.add(notional);
            // Liquidity tokens cannot be reduced below zero.
            if (AssetHandler.isLiquidityToken(assetType)) {
                require(newNotional >= 0); // dev: portfolio handler negative liquidity token balance
            }

            require(newNotional >= type(int88).min && newNotional <= type(int88).max); // dev: portfolio handler notional overflow

            asset.notional = newNotional;
            asset.storageState = AssetStorageState.Update;

            return true;
        }

        return false;
    }

    /// @notice Adds an asset to a portfolio state in memory (does not write to storage)
    /// @dev Ensures that only one version of an asset exists in a portfolio (i.e. does not allow two fCash assets of the same maturity
    /// to exist in a single portfolio). Also ensures that liquidity tokens do not have a negative notional.
    function addAsset(
        PortfolioState memory portfolioState,
        uint16 currencyId,
        uint256 maturity,
        uint256 assetType,
        int256 notional
    ) internal pure {
        if (
            // Will return true if merged
            _mergeAssetIntoArray(
                portfolioState.storedAssets,
                currencyId,
                maturity,
                assetType,
                notional
            )
        ) return;

        if (portfolioState.lastNewAssetIndex > 0) {
            bool merged = _mergeAssetIntoArray(
                portfolioState.newAssets,
                currencyId,
                maturity,
                assetType,
                notional
            );
            if (merged) return;
        }

        // At this point if we have not merged the asset then append to the array
        // Cannot remove liquidity that the portfolio does not have
        if (AssetHandler.isLiquidityToken(assetType)) {
            require(notional >= 0); // dev: portfolio handler negative liquidity token balance
        }
        require(notional >= type(int88).min && notional <= type(int88).max); // dev: portfolio handler notional overflow

        // Need to provision a new array at this point
        if (portfolioState.lastNewAssetIndex == portfolioState.newAssets.length) {
            portfolioState.newAssets = _extendNewAssetArray(portfolioState.newAssets);
        }

        // Otherwise add to the new assets array. It should not be possible to add matching assets in a single transaction, we will
        // check this again when we write to storage. Assigning to memory directly here, do not allocate new memory via struct.
        PortfolioAsset memory newAsset = portfolioState.newAssets[portfolioState.lastNewAssetIndex];
        newAsset.currencyId = currencyId;
        newAsset.maturity = maturity;
        newAsset.assetType = assetType;
        newAsset.notional = notional;
        newAsset.storageState = AssetStorageState.NoChange;
        portfolioState.lastNewAssetIndex += 1;
    }

    /// @dev Extends the new asset array if it is not large enough, this is likely to get a bit expensive if we do
    /// it too much
    function _extendNewAssetArray(PortfolioAsset[] memory newAssets)
        private
        pure
        returns (PortfolioAsset[] memory)
    {
        // Double the size of the new asset array every time we have to extend to reduce the number of times
        // that we have to extend it. This will go: 0, 1, 2, 4, 8 (probably stops there).
        uint256 newLength = newAssets.length == 0 ? 1 : newAssets.length * 2;
        PortfolioAsset[] memory extendedArray = new PortfolioAsset[](newLength);
        for (uint256 i = 0; i < newAssets.length; i++) {
            extendedArray[i] = newAssets[i];
        }

        return extendedArray;
    }

    /// @notice Takes a portfolio state and writes it to storage.
    /// @dev This method should only be called directly by the nToken. Account updates to portfolios should happen via
    /// the storeAssetsAndUpdateContext call in the AccountContextHandler.sol library.
    /// @return updated variables to update the account context with
    ///     hasDebt: whether or not the portfolio has negative fCash assets
    ///     portfolioActiveCurrencies: a byte32 word with all the currencies in the portfolio
    ///     uint8: the length of the storage array
    ///     uint40: the new nextSettleTime for the portfolio
    function storeAssets(PortfolioState memory portfolioState, address account)
        internal
        returns (
            bool,
            bytes32,
            uint8,
            uint40
        )
    {
        bool hasDebt;
        // NOTE: cannot have more than 16 assets or this byte object will overflow. Max assets is
        // set to 7 and the worst case during liquidation would be 7 liquidity tokens that generate
        // 7 additional fCash assets for a total of 14 assets. Although even in this case all assets
        // would be of the same currency so it would not change the end result of the active currency
        // calculation.
        bytes32 portfolioActiveCurrencies;
        uint256 nextSettleTime;

        for (uint256 i = 0; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            // NOTE: this is to prevent the storage of assets that have been modified in the AssetHandler
            // during valuation.
            require(asset.storageState != AssetStorageState.RevertIfStored);

            // Mark any zero notional assets as deleted
            if (asset.storageState != AssetStorageState.Delete && asset.notional == 0) {
                deleteAsset(portfolioState, i);
            }
        }

        // First delete assets from asset storage to maintain asset storage indexes
        for (uint256 i = 0; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];

            if (asset.storageState == AssetStorageState.Delete) {
                // Delete asset from storage
                uint256 currentSlot = asset.storageSlot;
                assembly {
                    sstore(currentSlot, 0x00)
                }
            } else {
                if (asset.storageState == AssetStorageState.Update) {
                    PortfolioAssetStorage storage assetStorage;
                    uint256 currentSlot = asset.storageSlot;
                    assembly {
                        assetStorage.slot := currentSlot
                    }

                    _storeAsset(asset, assetStorage);
                }

                // Update portfolio context for every asset that is in storage, whether it is
                // updated in storage or not.
                (hasDebt, portfolioActiveCurrencies, nextSettleTime) = _updatePortfolioContext(
                    asset,
                    hasDebt,
                    portfolioActiveCurrencies,
                    nextSettleTime
                );
            }
        }

        // Add new assets
        uint256 assetStorageLength = portfolioState.storedAssetLength;
        mapping(address => 
            PortfolioAssetStorage[MAX_PORTFOLIO_ASSETS]) storage store = LibStorage.getPortfolioArrayStorage();
        PortfolioAssetStorage[MAX_PORTFOLIO_ASSETS] storage storageArray = store[account];
        for (uint256 i = 0; i < portfolioState.newAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.newAssets[i];
            if (asset.notional == 0) continue;
            require(
                asset.storageState != AssetStorageState.Delete &&
                asset.storageState != AssetStorageState.RevertIfStored
            ); // dev: store assets deleted storage

            (hasDebt, portfolioActiveCurrencies, nextSettleTime) = _updatePortfolioContext(
                asset,
                hasDebt,
                portfolioActiveCurrencies,
                nextSettleTime
            );

            _storeAsset(asset, storageArray[assetStorageLength]);
            assetStorageLength += 1;
        }

        // 16 is the maximum number of assets or portfolio active currencies will overflow its
        // 32 bytes size given 2 bytes per currency
        require(assetStorageLength <= 16); // dev: active currencies bytes32 overflow
        require(nextSettleTime <= type(uint40).max); // dev: portfolio return value overflow
        return (
            hasDebt,
            portfolioActiveCurrencies,
            uint8(assetStorageLength),
            uint40(nextSettleTime)
        );
    }

    /// @notice Updates context information during the store assets method
    function _updatePortfolioContext(
        PortfolioAsset memory asset,
        bool hasDebt,
        bytes32 portfolioActiveCurrencies,
        uint256 nextSettleTime
    )
        private
        pure
        returns (
            bool,
            bytes32,
            uint256
        )
    {
        uint256 settlementDate = asset.getSettlementDate();
        // Tis will set it to the minimum settlement date
        if (nextSettleTime == 0 || nextSettleTime > settlementDate) {
            nextSettleTime = settlementDate;
        }
        hasDebt = hasDebt || asset.notional < 0;

        require(uint16(uint256(portfolioActiveCurrencies)) == 0); // dev: portfolio active currencies overflow
        portfolioActiveCurrencies = 
            (portfolioActiveCurrencies >> 16) | 
            (bytes32(uint256(asset.currencyId)) << 240);

        return (hasDebt, portfolioActiveCurrencies, nextSettleTime);
    }

    /// @dev Encodes assets for storage
    function _storeAsset(
        PortfolioAsset memory asset,
        PortfolioAssetStorage storage assetStorage
    ) internal {
        require(0 < asset.currencyId && asset.currencyId <= Constants.MAX_CURRENCIES); // dev: encode asset currency id overflow
        require(0 < asset.maturity && asset.maturity <= type(uint40).max); // dev: encode asset maturity overflow
        require(0 < asset.assetType && asset.assetType <= Constants.MAX_LIQUIDITY_TOKEN_INDEX); // dev: encode asset type invalid
        require(type(int88).min <= asset.notional && asset.notional <= type(int88).max); // dev: encode asset notional overflow

        assetStorage.currencyId = uint16(asset.currencyId);
        assetStorage.maturity = uint40(asset.maturity);
        assetStorage.assetType = uint8(asset.assetType);
        assetStorage.notional = int88(asset.notional);
    }

    /// @notice Deletes an asset from a portfolio
    /// @dev This method should only be called during settlement, assets can only be removed from a portfolio before settlement
    /// by adding the offsetting negative position
    function deleteAsset(PortfolioState memory portfolioState, uint256 index) internal pure {
        require(index < portfolioState.storedAssets.length); // dev: stored assets bounds
        require(portfolioState.storedAssetLength > 0); // dev: stored assets length is zero
        PortfolioAsset memory assetToDelete = portfolioState.storedAssets[index];
        require(
            assetToDelete.storageState != AssetStorageState.Delete &&
            assetToDelete.storageState != AssetStorageState.RevertIfStored
        ); // dev: cannot delete asset

        portfolioState.storedAssetLength -= 1;

        uint256 maxActiveSlotIndex;
        uint256 maxActiveSlot;
        // The max active slot is the last storage slot where an asset exists, it's not clear where this will be in the
        // array so we search for it here.
        for (uint256 i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory a = portfolioState.storedAssets[i];
            if (a.storageSlot > maxActiveSlot && a.storageState != AssetStorageState.Delete) {
                maxActiveSlot = a.storageSlot;
                maxActiveSlotIndex = i;
            }
        }

        if (index == maxActiveSlotIndex) {
            // In this case we are deleting the asset with the max storage slot so no swap is necessary.
            assetToDelete.storageState = AssetStorageState.Delete;
            return;
        }

        // Swap the storage slots of the deleted asset with the last non-deleted asset in the array. Mark them accordingly
        // so that when we call store assets they will be updated appropriately
        PortfolioAsset memory assetToSwap = portfolioState.storedAssets[maxActiveSlotIndex];
        (
            assetToSwap.storageSlot,
            assetToDelete.storageSlot
        ) = (
            assetToDelete.storageSlot,
            assetToSwap.storageSlot
        );
        assetToSwap.storageState = AssetStorageState.Update;
        assetToDelete.storageState = AssetStorageState.Delete;
    }

    /// @notice Returns a portfolio array, will be sorted
    function getSortedPortfolio(address account, uint8 assetArrayLength)
        internal view returns (PortfolioAsset[] memory assets) {
        (assets, /* */) = getSortedPortfolioWithIds(account, assetArrayLength);
    }

    function getSortedPortfolioWithIds(address account, uint8 assetArrayLength)
        internal view returns (PortfolioAsset[] memory assets, uint256[] memory ids) {
        assets = _loadAssetArray(account, assetArrayLength);
        ids = _sortInPlace(assets);
    }

    /// @notice Builds a portfolio array from storage. The new assets hint parameter will
    /// be used to provision a new array for the new assets. This will increase gas efficiency
    /// so that we don't have to make copies when we extend the array.
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

    function _sortId(uint16 currencyId, uint256 maturity, uint256 assetType) private pure returns (uint256) {
        return uint256(
            (bytes32(uint256(currencyId)) << 48) |
                (bytes32(uint256(uint40(maturity))) << 8) |
                bytes32(uint256(uint8(assetType)))
        );
    }

    function _sortInPlace(
        PortfolioAsset[] memory assets
    ) private pure returns (uint256[] memory ids) {
        uint256 length = assets.length;
        ids = new uint256[](length);
        for (uint256 k; k < length; k++) {
            PortfolioAsset memory asset = assets[k];
            // Prepopulate the ids to calculate just once
            ids[k] = _sortId(asset.currencyId, asset.maturity, asset.assetType);
        }

        // Uses insertion sort 
        uint256 i = 1;
        while (i < length) {
            uint256 j = i;
            while (j > 0 && ids[j - 1] > ids[j]) {
                // Swap j - 1 and j
                (ids[j - 1], ids[j]) = (ids[j], ids[j - 1]);
                (assets[j - 1], assets[j]) = (assets[j], assets[j - 1]);
                j--;
            }
            i++;
        }
    }

    function _loadAssetArray(address account, uint8 length)
        private
        view
        returns (PortfolioAsset[] memory)
    {
        // This will overflow the storage pointer
        require(length <= MAX_PORTFOLIO_ASSETS);

        mapping(address => 
            PortfolioAssetStorage[MAX_PORTFOLIO_ASSETS]) storage store = LibStorage.getPortfolioArrayStorage();
        PortfolioAssetStorage[MAX_PORTFOLIO_ASSETS] storage storageArray = store[account];
        PortfolioAsset[] memory assets = new PortfolioAsset[](length);

        for (uint256 i = 0; i < length; i++) {
            PortfolioAssetStorage storage assetStorage = storageArray[i];
            PortfolioAsset memory asset = assets[i];
            uint256 slot;
            assembly {
                slot := assetStorage.slot
            }

            asset.currencyId = assetStorage.currencyId;
            asset.maturity = assetStorage.maturity;
            asset.assetType = assetStorage.assetType;
            asset.notional = assetStorage.notional;
            asset.storageSlot = slot;
        }

        return assets;
    }
}
