// SPDX-License-Identifier: BSUL-1.1
pragma solidity >=0.7.6;

interface WETH9 {
    function deposit() external payable;

    function withdraw(uint256 wad) external;

    function transfer(address dst, uint256 wad) external returns (bool);
}
