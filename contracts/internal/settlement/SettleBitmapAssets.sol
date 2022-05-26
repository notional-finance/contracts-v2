// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../markets/AssetRate.sol";
import "../../global/LibStorage.sol";
import "../portfolio/BitmapAssetsHandler.sol";
import "../../math/SafeInt256.sol";
import "../../math/Bitmap.sol";
import "../../global/Constants.sol";
import "../../global/Types.sol";

/**
 * Settles a bitmap portfolio by checking for all matured fCash assets and turning them into cash
 * at the prevailing settlement rate. It will also update the asset bitmap to ensure that it continues
 * to correctly reference all actual maturities. fCash asset notional values are stored in *absolute* 
 * time terms and bitmap bits are *relative* time terms based on the bitNumber and the stored oldSettleTime.
 * Remapping bits requires converting the old relative bit numbers to new relative bit numbers based on
 * newSettleTime and the absolute times (maturities) that the previous bitmap references.
 */
library SettleBitmapAssets {
    using SafeInt256 for int256;
    using AssetRate for AssetRateParameters;
    using Bitmap for bytes32;

    /// @notice Given a bitmap for a cash group and timestamps, will settle all assets
    /// that have matured and remap the bitmap to correspond to the current time.
    function settleBitmappedCashGroup(
        address account,
        uint256 currencyId,
        uint256 oldSettleTime,
        uint256 blockTime
    ) internal returns (int256 totalAssetCash, uint256 newSettleTime) {
        bytes32 bitmap = BitmapAssetsHandler.getAssetsBitmap(account, currencyId);

        // This newSettleTime will be set to the new `oldSettleTime`. The bits between 1 and
        // `lastSettleBit` (inclusive) will be shifted out of the bitmap and settled. The reason
        // that lastSettleBit is inclusive is that it refers to newSettleTime which always less
        // than the current block time.
        newSettleTime = DateTime.getTimeUTC0(blockTime);
        // If newSettleTime == oldSettleTime lastSettleBit will be zero
        require(newSettleTime >= oldSettleTime); // dev: new settle time before previous

        // Do not need to worry about validity, if newSettleTime is not on an exact bit we will settle up until
        // the closest maturity that is less than newSettleTime.
        (uint256 lastSettleBit, /* isValid */) = DateTime.getBitNumFromMaturity(oldSettleTime, newSettleTime);
        if (lastSettleBit == 0) return (totalAssetCash, newSettleTime);

        // Returns the next bit that is set in the bitmap
        uint256 nextBitNum = bitmap.getNextBitNum();
        while (nextBitNum != 0 && nextBitNum <= lastSettleBit) {
            uint256 maturity = DateTime.getMaturityFromBitNum(oldSettleTime, nextBitNum);
            totalAssetCash = totalAssetCash.add(
                _settlefCashAsset(account, currencyId, maturity, blockTime)
            );

            // Turn the bit off now that it is settled
            bitmap = bitmap.setBit(nextBitNum, false);
            nextBitNum = bitmap.getNextBitNum();
        }

        bytes32 newBitmap;
        while (nextBitNum != 0) {
            uint256 maturity = DateTime.getMaturityFromBitNum(oldSettleTime, nextBitNum);
            (uint256 newBitNum, bool isValid) = DateTime.getBitNumFromMaturity(newSettleTime, maturity);
            require(isValid); // dev: invalid new bit num

            newBitmap = newBitmap.setBit(newBitNum, true);

            // Turn the bit off now that it is remapped
            bitmap = bitmap.setBit(nextBitNum, false);
            nextBitNum = bitmap.getNextBitNum();
        }

        BitmapAssetsHandler.setAssetsBitmap(account, currencyId, newBitmap);
    }

    /// @dev Stateful settlement function to settle a bitmapped asset. Deletes the
    /// asset from storage after calculating it.
    function _settlefCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) private returns (int256 assetCash) {
        mapping(address => mapping(uint256 =>
            mapping(uint256 => ifCashStorage))) storage store = LibStorage.getifCashBitmapStorage();
        int256 notional = store[account][currencyId][maturity].notional;
        
        // Gets the current settlement rate or will store a new settlement rate if it does not
        // yet exist.
        AssetRateParameters memory rate =
            AssetRate.buildSettlementRateStateful(currencyId, maturity, blockTime);
        assetCash = rate.convertFromUnderlying(notional);

        delete store[account][currencyId][maturity];

        return assetCash;
    }
}
