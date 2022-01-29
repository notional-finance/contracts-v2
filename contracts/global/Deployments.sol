// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

import "interfaces/aave/ILendingPool.sol";

/// @title Hardcoded deployed contracts are listed here. These are hardcoded to reduce
/// gas costs for immutable addresses. They must be updated per environment that Notional
/// is deployed to.
library Deployments {
    address internal constant NOTE_TOKEN_ADDRESS = 0xCFEAead4947f0705A14ec42aC3D44129E1Ef3eD5;
    /// @dev This is hardcoded for ETH Mainnet (Main Market), different environments will need
    /// to have a different LendingPool specified
    ILendingPool internal constant LendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
}
