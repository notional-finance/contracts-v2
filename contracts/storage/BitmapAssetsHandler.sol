// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/CashGroup.sol";
import "../common/AssetHandler.sol";
import "../math/Bitmap.sol";
import "../math/SafeInt256.sol";

library BitmapAssetsHandler {
    using SafeInt256 for int;
    using Bitmap for bytes;
    using CashGroup for CashGroupParameters;

    uint internal constant IFCASH_STORAGE_SLOT = 4;

    function getAssetsBitmap(
        address account,
        uint currencyId
    ) internal view returns (bytes memory) {
        bytes32 slot = keccak256(abi.encode(account, currencyId, "assets.bitmap"));
        bytes32 data;

        assembly { data := sload(slot) }

        // TODO: is it more efficient to ensure that this always returns a bytes memory
        // of length 32?
        return abi.encodePacked(data);
    }

    function setAssetsBitmap(
        address account,
        uint currencyId,
        bytes memory assetsBitmap
    ) internal {
        bytes32 slot = keccak256(abi.encode(account, currencyId, "assets.bitmap"));
        require(assetsBitmap.length <= 32, "BM: bitmap too large");
        bytes32 data;

        // TODO: can this be turned into assembly?
        for (uint i; i < assetsBitmap.length; i++) {
            // Pack the assetsBitmap into a 32 byte storage slot
            data = data | (bytes32(assetsBitmap[i]) >> (i * 8));
        }
        assembly { sstore(slot, data) }
    }

    function getifCashSlot(
        address account,
        uint currencyId,
        uint maturity
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(maturity,
            keccak256(abi.encode(currencyId,
                keccak256(abi.encode(account, IFCASH_STORAGE_SLOT))
            ))
        ));
    }

    /**
     * @notice Set an ifCash asset in the bitmap and mapping. Updates the bitmap in memory but not in storage.
     */
    function setifCashAsset(
        address account,
        uint currencyId,
        uint maturity,
        uint nextMaturingAsset,
        int notional,
        bytes memory assetsBitmap
    ) internal returns (bytes memory) {
        bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
        (uint bitNum, bool isExact) = CashGroup.getBitNumFromMaturity(nextMaturingAsset, maturity);
        require(isExact, "BM: invalid maturity");

        if (assetsBitmap.isBitSet(bitNum)) {
            // Bit is set so we read and update the notional amount
            int existingNotional;
            assembly { existingNotional := sload(fCashSlot) }
            existingNotional = existingNotional.add(notional);
            assembly { sstore(fCashSlot, existingNotional) }

            // If the new notional is zero then turn off the bit
            if (existingNotional == 0) {
                assetsBitmap = assetsBitmap.setBit(bitNum, false);
            }
        } else {
            // Bit is not set so we turn it on and update the mapping directly, no read required.
            assembly { sstore(fCashSlot, notional) }
            assetsBitmap = assetsBitmap.setBit(bitNum, true);
        }

        return assetsBitmap;
    }

    function getPresentValue(
        address account,
        uint currencyId,
        uint maturity,
        uint blockTime,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        bool riskAdjusted
    ) internal view returns (int) {
        bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
        int notional;
        assembly { notional := sload(fCashSlot) }

        // In this case the asset has matured and the total value is set
        if (maturity <= blockTime) return notional;

        uint oracleRate = cashGroup.getOracleRate(markets, maturity, blockTime);
        if (riskAdjusted) {
            return AssetHandler.getRiskAdjustedPresentValue(
                cashGroup,
                notional,
                maturity,
                blockTime,
                oracleRate
            );
        }

        return AssetHandler.getPresentValue(
            notional,
            maturity,
            blockTime,
            oracleRate
        );
    }

    /**
     * @notice Get the net present value of all the ifCash assets
     */
    function getifCashNetPresentValue(
        address account,
        uint currencyId,
        uint nextMaturingAsset,
        uint blockTime,
        bytes memory assetsBitmap,
        CashGroupParameters memory cashGroup,
        MarketParameters[] memory markets,
        bool riskAdjusted
    ) internal view returns (int) {
        int totalValueUnderlying;

        for (uint i; i < assetsBitmap.length; i++) {
            if (assetsBitmap[i] == 0x00) continue;
            bytes1 assetByte = assetsBitmap[i];

            // Loop over each bit in the byte, it's position is referenced as 1-indexed
            for (uint bit = 1; bit <= 8; bit++) {
                if (assetByte == 0x00) break;
                if (assetByte & Bitmap.BIT1 != Bitmap.BIT1) {
                    assetByte = assetByte << 1;
                    continue;
                }

                uint maturity = CashGroup.getMaturityFromBitNum(nextMaturingAsset, i * 8 + bit);
                totalValueUnderlying = totalValueUnderlying.add(getPresentValue(
                    account,
                    currencyId,
                    maturity,
                    blockTime,
                    cashGroup,
                    markets,
                    riskAdjusted
                ));

                assetByte = assetByte << 1;
            }
        }

        return totalValueUnderlying;
    }

    function getifCashArray(
        address account,
        uint currencyId,
        uint nextMaturingAsset
    ) internal view returns (PortfolioAsset[] memory) {
        bytes memory assetsBitmap = getAssetsBitmap(account, currencyId);
        uint index = assetsBitmap.totalBitsSet();
        PortfolioAsset[] memory assets = new PortfolioAsset[](index);
        index = 0;

        for (uint i; i < assetsBitmap.length; i++) {
            if (assetsBitmap[i] == 0x00) continue;
            bytes1 assetByte = assetsBitmap[i];

            // Loop over each bit in the byte, it's position is referenced as 1-indexed
            for (uint bit = 1; bit <= 8; bit++) {
                if (assetByte == 0x00) break;
                if (assetByte & Bitmap.BIT1 != Bitmap.BIT1) {
                    assetByte = assetByte << 1;
                    continue;
                }
                uint maturity = CashGroup.getMaturityFromBitNum(nextMaturingAsset, i * 8 + bit);
                int notional;

                {
                    bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
                    assembly { notional := sload(fCashSlot) }
                }

                assets[index].currencyId = currencyId;
                assets[index].maturity = maturity;
                assets[index].assetType = AssetHandler.FCASH_ASSET_TYPE;
                assets[index].notional = notional;
                index += 1;

                assetByte = assetByte << 1;
                if (index == assets.length) return assets;
            }
        }

        return assets;
    }

    /**
     * @notice Used to reduce a perpetual token ifCash assets portfolio proportionately
     */
    function reduceifCashAssetsProportional(
        address account,
        uint currencyId,
        uint nextMaturingAsset,
        int tokensToRedeem,
        int totalSupply
    ) internal returns (PortfolioAsset[] memory) {
        bytes memory assetsBitmap = getAssetsBitmap(account, currencyId);
        uint index = assetsBitmap.totalBitsSet();
        PortfolioAsset[] memory assets = new PortfolioAsset[](index);
        index = 0;

        for (uint i; i < assetsBitmap.length; i++) {
            if (assetsBitmap[i] == 0x00) continue;
            bytes1 assetByte = assetsBitmap[i];

            // Loop over each bit in the byte, it's position is referenced as 1-indexed
            for (uint bit = 1; bit <= 8; bit++) {
                if (assetByte == 0x00) break;
                if (assetByte & Bitmap.BIT1 != Bitmap.BIT1) {
                    assetByte = assetByte << 1;
                    continue;
                }
                uint maturity = CashGroup.getMaturityFromBitNum(nextMaturingAsset, i * 8 + bit);
                bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
                int notional;
                assembly { notional := sload(fCashSlot) }

                int notionalToTransfer = notional.mul(tokensToRedeem).div(totalSupply);
                notional = notional.sub(notionalToTransfer);
                assembly { sstore(fCashSlot, notional) }

                assets[index].currencyId = currencyId;
                assets[index].maturity = maturity;
                assets[index].assetType = AssetHandler.FCASH_ASSET_TYPE;
                assets[index].notional = notionalToTransfer;
                index += 1;

                assetByte = assetByte << 1;
                if (index == assets.length) break;
            }
        }

        // If the entire token supply is redeemed then the assets bitmap will have been reduced to zero.
        // Because solidity truncates division there will always be dust left unless the entire supply is
        // redeemed.
        if (tokensToRedeem == totalSupply) {
            // TODO: swittch this to just bytes32
            setAssetsBitmap(account, currencyId, new bytes(32));
        }

        return assets;
    }

}