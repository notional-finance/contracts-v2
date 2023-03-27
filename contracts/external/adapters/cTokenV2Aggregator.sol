// SPDX-License-Identifier: BSUL-1.1
pragma solidity ^0.7.0;

import "./cTokenAggregator.sol";
import "../../../interfaces/compound/V2InterestRateModel.sol";

contract cTokenV2Aggregator is cTokenAggregator {

    constructor(CTokenInterface _cToken) cTokenAggregator(_cToken) {}

    function _getBorrowRate(
        uint256 totalCash,
        uint256 borrowsPrior,
        uint256 reservesPrior
    ) internal view override returns (uint256) {
        return
            V2InterestRateModel(cToken.interestRateModel()).getBorrowRate(
                totalCash,
                borrowsPrior,
                reservesPrior
            );
    }
}
