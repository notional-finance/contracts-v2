// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {PrimeRate, ifCashStorage} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {Bitmap} from "../../math/Bitmap.sol";

import {DateTime} from "../markets/DateTime.sol";
import {PrimeRateLib} from "../pCash/PrimeRateLib.sol";
import {BitmapAssetsHandler} from "../portfolio/BitmapAssetsHandler.sol";

/**
 * Settles a bitmap portfolio by checking for all matured fCash assets and turning them into cash
 * at the prevailing settlement rate. It will also update the asset bitmap to ensure that it continues
 * to correctly reference all actual maturities. fCash asset notional values are stored in *absolute* 
 * time terms and bitmap bits are *relative* time terms based on the bitNumber and the stored oldSettleTime.
 * Remapping bits requires converting the old relative bit numbers to new relative bit numbers based on
 * newSettleTime and the absolute times (maturities) that the previous bitmap references.
 */
library SettleBitmapAssets {
    using PrimeRateLib for PrimeRate;
    using SafeInt256 for int256;
    using Bitmap for bytes32;

    /// @notice Given a bitmap for a cash group and timestamps, will settle all assets
    /// that have matured and remap the bitmap to correspond to the current time.
    function settleBitmappedCashGroup(
        address account,
        uint16 currencyId,
        uint256 oldSettleTime,
        uint256 blockTime,
        PrimeRate memory presentPrimeRate
    ) internal returns (int256 positiveSettledCash, int256 negativeSettledCash, uint256 newSettleTime) {
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
        if (lastSettleBit == 0) return (0, 0, newSettleTime);

        // Returns the next bit that is set in the bitmap
        uint256 nextBitNum = bitmap.getNextBitNum();
        while (nextBitNum != 0 && nextBitNum <= lastSettleBit) {
            uint256 maturity = DateTime.getMaturityFromBitNum(oldSettleTime, nextBitNum);
            int256 settledPrimeCash = _settlefCashAsset(account, currencyId, maturity, blockTime, presentPrimeRate);

            // Split up positive and negative amounts so that total prime debt can be properly updated later
            if (settledPrimeCash > 0) {
                positiveSettledCash = positiveSettledCash.add(settledPrimeCash);
            } else {
                negativeSettledCash = negativeSettledCash.add(settledPrimeCash);
            }

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
        uint16 currencyId,
        uint256 maturity,
        uint256 blockTime,
        PrimeRate memory presentPrimeRate
    ) private returns (int256 signedPrimeSupplyValue) {
        mapping(address => mapping(uint256 =>
            mapping(uint256 => ifCashStorage))) storage store = LibStorage.getifCashBitmapStorage();
        int256 notional = store[account][currencyId][maturity].notional;
        
        // Gets the current settlement rate or will store a new settlement rate if it does not
        // yet exist.
        signedPrimeSupplyValue = presentPrimeRate.convertSettledfCash(
            account, currencyId, maturity, notional, blockTime
        );

        delete store[account][currencyId][maturity];
    }
}
