// SPDX-License-Identifier: BSUL-1.1
pragma solidity ^0.7.0;

import "./cTokenAggregator.sol";
import "../../../interfaces/compound/LegacyInterestRateModel.sol";

contract cTokenLegacyAggregator is cTokenAggregator {
    constructor(CTokenInterface _cToken) cTokenAggregator(_cToken) {}

    function _getBorrowRate(
        uint256 totalCash,
        uint256 borrowsPrior,
        uint256 reservesPrior
    ) internal view override returns (uint256) {
        // prettier-ignore
        (
            /* uint256 err */, 
            uint256 rate
        ) = LegacyInterestRateModel(cToken.interestRateModel()).getBorrowRate(
            totalCash,
            borrowsPrior,
            reservesPrior
        );
        return rate;
    }
}
