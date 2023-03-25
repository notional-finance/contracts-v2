// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.7.6;

interface IEulerEToken {
    function balanceOfUnderlying(address account) external view returns (uint);
    function convertBalanceToUnderlying(uint balance) external view returns (uint);
    function convertUnderlyingToBalance(uint underlyingAmount) external view returns (uint);
    function deposit(uint subAccountId, uint amount) external;
    function withdraw(uint subAccountId, uint amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}