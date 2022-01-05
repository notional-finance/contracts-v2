// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

interface NotionalTreasury {
    function claimCOMP(address[] calldata ctokens) external returns (uint256);

    function transferReserveToTreasury(address[] calldata assets)
        external
        returns (uint256[] memory);

    function setTreasuryManager(address manager) external;

    function setReserveBuffer(address asset, uint256 amount) external;
}
