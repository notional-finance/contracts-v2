// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.7.6;

interface IEulerStakingPool {
    function balanceOf(address account) external view returns (uint256);
    function stake(uint subAccountId, uint256 amount) external;
    function withdraw(uint subAccountId, uint256 amount) external;
}