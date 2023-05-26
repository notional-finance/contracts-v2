// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.7.6;

interface CTokenInterfaceV3 {
    function withdraw(address asset, uint256 amount) external;
    function supply(address asset, uint amount) external;
}
