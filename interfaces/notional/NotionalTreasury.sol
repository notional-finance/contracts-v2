// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

interface NotionalTreasury {
    function claimCOMP(address[] calldata ctokens) external returns (uint256);

    function transferReserveToTreasury(uint16[] calldata currencies)
        external
        returns (uint256[] memory);

    function getTreasuryManager() external view returns (address);

    function setTreasuryManager(address manager) external;

    function getReserveBuffer(uint16 currencyId) external view returns(uint256);

    function setReserveBuffer(uint16 currencyId, uint256 amount) external;
}
