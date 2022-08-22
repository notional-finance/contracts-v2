// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.7.6;

/// @title Hardcoded deployed contracts are listed here. These are hardcoded to reduce
/// gas costs for immutable addresses. They must be updated per environment that Notional
/// is deployed to.
library Deployments {
    address internal constant NOTE_TOKEN_ADDRESS = 0xCFEAead4947f0705A14ec42aC3D44129E1Ef3eD5;
}
