// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

interface Comptroller {
    function claimComp(address holder, address[] calldata ctokens) external;
}
