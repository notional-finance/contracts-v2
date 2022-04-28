// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.7.0;

interface V2InterestRateModel {
    function getBorrowRate(
        uint256,
        uint256,
        uint256
    ) external view returns (uint256);
}
