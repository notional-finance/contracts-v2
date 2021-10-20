// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;
pragma abicoder v2;

import "../AccountContextHandler.sol";
import "../markets/CashGroup.sol";
import "../valuation/AssetHandler.sol";
import "../../math/Bitmap.sol";
import "../../math/SafeInt256.sol";
import "../../math/UserDefinedType.sol";
import "../../global/LibStorage.sol";
import "../../global/Constants.sol";
import "../../global/Types.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

library BitmapAssetsHandler {
    using UserDefinedType for IU;
    using UserDefinedType for IA;
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using Bitmap for bytes32;
    using CashGroup for CashGroupParameters;
    using AccountContextHandler for AccountContext;

    function getAssetsBitmap(address account, uint256 currencyId) internal view returns (bytes32 assetsBitmap) {
        mapping(address => mapping(uint256 => bytes32)) storage store = LibStorage.getAssetsBitmapStorage();
        return store[account][currencyId];
    }

    function setAssetsBitmap(
        address account,
        uint256 currencyId,
        bytes32 assetsBitmap
    ) internal {
        require(assetsBitmap.totalBitsSet() <= Constants.MAX_BITMAP_ASSETS, "Over max assets");
        mapping(address => mapping(uint256 => bytes32)) storage store = LibStorage.getAssetsBitmapStorage();
        store[account][currencyId] = assetsBitmap;
    }

    function getifCashNotional(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) internal view returns (IU notional) {
        mapping(address => mapping(uint256 =>
            mapping(uint256 => ifCashStorage))) storage store = LibStorage.getifCashBitmapStorage();
        return IU.wrap(int256(store[account][currencyId][maturity].notional));
    }

    /// @notice Adds multiple assets to a bitmap portfolio
    function addMultipleifCashAssets(
        address account,
        AccountContext memory accountContext,
        PortfolioAsset[] memory assets
    ) internal {
        require(accountContext.isBitmapEnabled()); // dev: bitmap currency not set
        uint256 currencyId = accountContext.bitmapCurrencyId;

        for (uint256 i; i < assets.length; i++) {
            PortfolioAsset memory asset = assets[i];
            if (asset.notional == 0) continue;

            require(asset.currencyId == currencyId); // dev: invalid asset in set ifcash assets
            require(asset.assetType == Constants.FCASH_ASSET_TYPE); // dev: invalid asset in set ifcash assets

            IU finalNotional = addifCashAsset(
                account,
                currencyId,
                asset.maturity,
                accountContext.nextSettleTime,
                IU.wrap(asset.notional)
            );

            if (finalNotional.isNegNotZero())
                accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_ASSET_DEBT;
        }
    }

    /// @notice Add an ifCash asset in the bitmap and mapping. Updates the bitmap in memory
    /// but not in storage.
    /// @return the updated assets bitmap and the final notional amount
    function addifCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 nextSettleTime,
        IU notional
    ) internal returns (IU) {
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        mapping(address => mapping(uint256 =>
            mapping(uint256 => ifCashStorage))) storage store = LibStorage.getifCashBitmapStorage();
        ifCashStorage storage fCashSlot = store[account][currencyId][maturity];
        (uint256 bitNum, bool isExact) = DateTime.getBitNumFromMaturity(nextSettleTime, maturity);
        require(isExact); // dev: invalid maturity in set ifcash asset

        if (assetsBitmap.isBitSet(bitNum)) {
            // Bit is set so we read and update the notional amount
            IU finalNotional = notional.add(IU.wrap(fCashSlot.notional));
            require(type(int128).min <= IU.unwrap(finalNotional) 
                && IU.unwrap(finalNotional) <= type(int128).max); // dev: bitmap notional overflow
            fCashSlot.notional = int128(IU.unwrap(finalNotional));

            // If the new notional is zero then turn off the bit
            if (finalNotional.isZero()) {
                assetsBitmap = assetsBitmap.setBit(bitNum, false);
            }

            setAssetsBitmap(account, currencyId, assetsBitmap);
            return finalNotional;
        }

        if (notional.isNotZero()) {
            // Bit is not set so we turn it on and update the mapping directly, no read required.
            require(type(int128).min <= IU.unwrap(notional) 
                && IU.unwrap(notional) <= type(int128).max); // dev: bitmap notional overflow
            fCashSlot.notional = int128(IU.unwrap(notional));

            assetsBitmap = assetsBitmap.setBit(bitNum, true);
            setAssetsBitmap(account, currencyId, assetsBitmap);
        }

        return notional;
    }

    /// @notice Returns the present value of an asset
    function _getPresentValue(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime,
        CashGroupParameters memory cashGroup,
        bool riskAdjusted
    ) private view returns (IU) {
        IU notional = getifCashNotional(account, currencyId, maturity);

        // In this case the asset has matured and the total value is just the notional amount
        if (maturity <= blockTime) {
            return notional;
        } else {
            IR oracleRate = cashGroup.calculateOracleRate(maturity, blockTime);
            if (riskAdjusted) {
                return AssetHandler.getRiskAdjustedPresentfCashValue(
                    cashGroup,
                    notional,
                    maturity,
                    blockTime,
                    oracleRate
                );
            } else {
                return AssetHandler.getPresentfCashValue(
                    notional,
                    maturity,
                    blockTime,
                    oracleRate
                );
            }
        }
    }

    /// @notice Get the net present value of all the ifCash assets
    function getifCashNetPresentValue(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime,
        uint256 blockTime,
        CashGroupParameters memory cashGroup,
        bool riskAdjusted
    ) internal view returns (IU totalValueUnderlying, bool hasDebt) {
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        uint256 bitNum = assetsBitmap.getNextBitNum();

        while (bitNum != 0) {
            uint256 maturity = DateTime.getMaturityFromBitNum(nextSettleTime, bitNum);
            IU pv = _getPresentValue(
                account,
                currencyId,
                maturity,
                blockTime,
                cashGroup,
                riskAdjusted
            );
            totalValueUnderlying = totalValueUnderlying.add(pv);

            if (IU.unwrap(pv) < 0) hasDebt = true;

            // Turn off the bit and look for the next one
            assetsBitmap = assetsBitmap.setBit(bitNum, false);
            bitNum = assetsBitmap.getNextBitNum();
        }
    }

    /// @notice Returns the ifCash assets as an array
    function getifCashArray(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime
    ) internal view returns (PortfolioAsset[] memory) {
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        uint256 index = assetsBitmap.totalBitsSet();
        PortfolioAsset[] memory assets = new PortfolioAsset[](index);
        index = 0;

        uint256 bitNum = assetsBitmap.getNextBitNum();
        while (bitNum != 0) {
            uint256 maturity = DateTime.getMaturityFromBitNum(nextSettleTime, bitNum);
            IU notional = getifCashNotional(account, currencyId, maturity);

            PortfolioAsset memory asset = assets[index];
            asset.currencyId = currencyId;
            asset.maturity = maturity;
            asset.assetType = Constants.FCASH_ASSET_TYPE;
            asset.notional = IU.unwrap(notional);
            index += 1;

            // Turn off the bit and look for the next one
            assetsBitmap = assetsBitmap.setBit(bitNum, false);
            bitNum = assetsBitmap.getNextBitNum();
        }

        return assets;
    }

    /// @notice Used to reduce an nToken ifCash assets portfolio proportionately when redeeming
    /// nTokens to its underlying assets.
    function reduceifCashAssetsProportional(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime,
        int256 tokensToRedeem,
        int256 totalSupply
    ) internal returns (PortfolioAsset[] memory) {
        // It is not possible to redeem the entire token supply because some liquidity tokens must remain
        // in the liquidity token portfolio in order to re-initialize markets.
        require(tokensToRedeem < totalSupply, "Cannot redeem");

        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        uint256 index = assetsBitmap.totalBitsSet();
        mapping(address => mapping(uint256 =>
            mapping(uint256 => ifCashStorage))) storage store = LibStorage.getifCashBitmapStorage();

        PortfolioAsset[] memory assets = new PortfolioAsset[](index);
        index = 0;

        uint256 bitNum = assetsBitmap.getNextBitNum();
        while (bitNum != 0) {
            uint256 maturity = DateTime.getMaturityFromBitNum(nextSettleTime, bitNum);
            ifCashStorage storage fCashSlot = store[account][currencyId][maturity];
            int256 notional = fCashSlot.notional;

            int256 notionalToTransfer = notional.mul(tokensToRedeem).div(totalSupply);
            int256 finalNotional = notional.sub(notionalToTransfer);

            require(type(int128).min <= finalNotional && finalNotional <= type(int128).max); // dev: bitmap notional overflow
            fCashSlot.notional = int128(finalNotional);

            PortfolioAsset memory asset = assets[index];
            asset.currencyId = currencyId;
            asset.maturity = maturity;
            asset.assetType = Constants.FCASH_ASSET_TYPE;
            asset.notional = notionalToTransfer;
            index += 1;

            // Turn off the bit and look for the next one
            assetsBitmap = assetsBitmap.setBit(bitNum, false);
            bitNum = assetsBitmap.getNextBitNum();
        }

        return assets;
    }
}
