// SPDX-License-Identifier: BSUL-1.1
pragma solidity >=0.7.6;

interface Comptroller {
    function claimComp(address holder, address[] calldata ctokens) external;

    function getCompAddress() external view returns (address);
}
