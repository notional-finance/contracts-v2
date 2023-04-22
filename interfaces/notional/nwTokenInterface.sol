// SPDX-License-Identifier: GPL-v3
pragma solidity >=0.7.6;
pragma abicoder v2;

interface nwTokenInterface {
    function initialize(uint256 finalExchangeRate) external;
    function mint() external payable;
    function mint(uint256 amount) external returns (uint);
    function redeem(uint256 redeemTokens) external returns (uint);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint);
}