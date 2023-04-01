// SPDX-License-Identifier: GPL-v3
pragma solidity >=0.7.6;
pragma abicoder v2;

interface ncTokenInterface {
    function initialize(uint256 finalExchangeRate) external;
    function mint() external payable;
    function mint(uint256 amount) external;
    function redeem(uint256 redeemTokens) external returns (uint);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint);
}