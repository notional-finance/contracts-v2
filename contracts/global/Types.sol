// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

/// @notice Used in SettleAssets for calculating bitmap shifts
struct SplitBitmap {
    bytes32 dayBits;
    bytes32 weekBits;
    bytes32 monthBits;
    bytes32 quarterBits;
}
