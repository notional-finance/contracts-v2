// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.7.6;

interface WETH9 {
    function deposit() external payable;

    function withdraw(uint256 wad) external;
}
