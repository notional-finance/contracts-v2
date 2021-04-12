// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

/**
 * @title All publicly accessible constants for the Notional system should be declared here.
 */
library Constants {
    /// @dev Used to when calculating the amount to deleverage of a market when minting incentives
    uint256 internal constant DELEVERAGE_BUFFER = 30000000; // 300 * Market.BASIS_POINT
}
