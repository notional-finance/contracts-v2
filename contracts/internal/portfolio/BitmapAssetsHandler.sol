// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    PrimeRate,
    CashGroupParameters,
    AccountContext,
    PortfolioAsset,
    ifCashStorage
} from "../../global/Types.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {Bitmap} from "../../math/Bitmap.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";

import {AccountContextHandler} from "../AccountContextHandler.sol";
import {CashGroup} from "../markets/CashGroup.sol";
import {DateTime} from "../markets/DateTime.sol";
import {AssetHandler} from "../valuation/AssetHandler.sol";
import {PrimeCashExchangeRate} from "../pCash/PrimeCashExchangeRate.sol";

library BitmapAssetsHandler {
    using SafeUint256 for uint256;
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
    ) internal view returns (int256 notional) {
        mapping(address => mapping(uint256 =>
            mapping(uint256 => ifCashStorage))) storage store = LibStorage.getifCashBitmapStorage();
        return store[account][currencyId][maturity].notional;
    }

    /// @notice Adds multiple assets to a bitmap portfolio
    function addMultipleifCashAssets(
        address account,
        AccountContext memory accountContext,
        PortfolioAsset[] memory assets
    ) internal {
        require(accountContext.isBitmapEnabled()); // dev: bitmap currency not set
        uint16 currencyId = accountContext.bitmapCurrencyId;

        for (uint256 i; i < assets.length; i++) {
            PortfolioAsset memory asset = assets[i];
            if (asset.notional == 0) continue;

            require(asset.currencyId == currencyId); // dev: invalid asset in set ifcash assets
            require(asset.assetType == Constants.FCASH_ASSET_TYPE); // dev: invalid asset in set ifcash assets
            int256 finalNotional;

            finalNotional = addifCashAsset(
                account,
                currencyId,
                asset.maturity,
                accountContext.nextSettleTime,
                asset.notional
            );

            if (finalNotional < 0)
                accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_ASSET_DEBT;
        }
    }

    /// @notice Add an ifCash asset in the bitmap and mapping. Updates the bitmap in memory
    /// but not in storage.
    /// @return the updated assets bitmap and the final notional amount
    function addifCashAsset(
        address account,
        uint16 currencyId,
        uint256 maturity,
        uint256 nextSettleTime,
        int256 notional
    ) internal returns (int256) {
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        mapping(address => mapping(uint256 =>
            mapping(uint256 => ifCashStorage))) storage store = LibStorage.getifCashBitmapStorage();
        ifCashStorage storage fCashSlot = store[account][currencyId][maturity];
        (uint256 bitNum, bool isExact) = DateTime.getBitNumFromMaturity(nextSettleTime, maturity);
        require(isExact); // dev: invalid maturity in set ifcash asset

        if (assetsBitmap.isBitSet(bitNum)) {
            // Bit is set so we read and update the notional amount
            int256 initialNotional = fCashSlot.notional;
            int256 finalNotional = notional.add(initialNotional);
            fCashSlot.notional = finalNotional.toInt128();

            PrimeCashExchangeRate.updateTotalfCashDebtOutstanding(
                account, currencyId, maturity, initialNotional, finalNotional
            );

            // If the new notional is zero then turn off the bit
            if (finalNotional == 0) {
                assetsBitmap = assetsBitmap.setBit(bitNum, false);
            }

            setAssetsBitmap(account, currencyId, assetsBitmap);
            return finalNotional;
        }

        if (notional != 0) {
            // Bit is not set so we turn it on and update the mapping directly, no read required.
            fCashSlot.notional = notional.toInt128();

            PrimeCashExchangeRate.updateTotalfCashDebtOutstanding(
                account,
                currencyId,
                maturity,
                0, // bit was not set, so initial notional value is zero
                notional
            );

            assetsBitmap = assetsBitmap.setBit(bitNum, true);
            setAssetsBitmap(account, currencyId, assetsBitmap);
        }

        return notional;
    }

    /// @notice Returns the present value of an asset
    function getPresentValue(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime,
        CashGroupParameters memory cashGroup,
        bool riskAdjusted
    ) internal view returns (int256) {
        int256 notional = getifCashNotional(account, currencyId, maturity);

        // In this case the asset has matured and the total value is just the notional amount
        if (maturity <= blockTime) {
            return notional;
        } else {
            if (riskAdjusted) {
                return AssetHandler.getRiskAdjustedPresentfCashValue(
                    cashGroup, notional, maturity, blockTime
                );
            } else {
                uint256 oracleRate = cashGroup.calculateOracleRate(maturity, blockTime);
                return AssetHandler.getPresentfCashValue(
                    notional,
                    maturity,
                    blockTime,
                    oracleRate
                );
            }
        }
    }

    function getNetPresentValueFromBitmap(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime,
        uint256 blockTime,
        CashGroupParameters memory cashGroup,
        bool riskAdjusted,
        bytes32 assetsBitmap
    ) internal view returns (int256 totalValueUnderlying, bool hasDebt) {
        uint256 bitNum = assetsBitmap.getNextBitNum();

        while (bitNum != 0) {
            uint256 maturity = DateTime.getMaturityFromBitNum(nextSettleTime, bitNum);
            int256 pv = getPresentValue(
                account,
                currencyId,
                maturity,
                blockTime,
                cashGroup,
                riskAdjusted
            );
            totalValueUnderlying = totalValueUnderlying.add(pv);

            if (pv < 0) hasDebt = true;

            // Turn off the bit and look for the next one
            assetsBitmap = assetsBitmap.setBit(bitNum, false);
            bitNum = assetsBitmap.getNextBitNum();
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
    ) internal view returns (int256 totalValueUnderlying, bool hasDebt) {
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        return getNetPresentValueFromBitmap(
            account,
            currencyId,
            nextSettleTime,
            blockTime,
            cashGroup,
            riskAdjusted,
            assetsBitmap
        );
    }

    /// @notice Returns the ifCash assets as an array
    function getifCashArray(
        address account,
        uint16 currencyId,
        uint256 nextSettleTime
    ) internal view returns (PortfolioAsset[] memory) {
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        uint256 index = assetsBitmap.totalBitsSet();
        PortfolioAsset[] memory assets = new PortfolioAsset[](index);
        index = 0;

        uint256 bitNum = assetsBitmap.getNextBitNum();
        while (bitNum != 0) {
            uint256 maturity = DateTime.getMaturityFromBitNum(nextSettleTime, bitNum);
            int256 notional = getifCashNotional(account, currencyId, maturity);

            PortfolioAsset memory asset = assets[index];
            asset.currencyId = currencyId;
            asset.maturity = maturity;
            asset.assetType = Constants.FCASH_ASSET_TYPE;
            asset.notional = notional;
            index += 1;

            // Turn off the bit and look for the next one
            assetsBitmap = assetsBitmap.setBit(bitNum, false);
            bitNum = assetsBitmap.getNextBitNum();
        }

        return assets;
    }

}
