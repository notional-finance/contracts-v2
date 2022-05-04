// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.7.0;

interface LegacyInterestRateModel {
    function getBorrowRate(
        uint256,
        uint256,
        uint256
    ) external view returns (uint256, uint256);
}
