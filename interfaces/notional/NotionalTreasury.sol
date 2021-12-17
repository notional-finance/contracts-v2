// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

interface NotionalTreasury {

    function claimCOMP() external returns (uint256);

    function setTreasuryManager(address manager) external;
}
