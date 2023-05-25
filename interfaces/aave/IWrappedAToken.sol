// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.7.6;

interface IWrappedAToken {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}