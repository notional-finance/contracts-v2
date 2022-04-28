// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

import "./cTokenAggregator.sol";
import "../../../interfaces/compound/LegacyInterestRateModel.sol";

contract cTokenLegacyAggregator is cTokenAggregator {
    address public immutable INTEREST_RATE_MODEL;

    constructor(CTokenInterface _cToken) cTokenAggregator(_cToken) {
        INTEREST_RATE_MODEL = _cToken.interestRateModel();
    }

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

    function getExchangeRateView() external view override returns (int256) {
        // Return stored exchange rate if interest rate model is updated.
        // This prevents the function from returning incorrect exchange rates
        uint256 exchangeRate = cToken.interestRateModel() == INTEREST_RATE_MODEL
            ? _viewExchangeRate()
            : cToken.exchangeRateStored();
        _checkExchangeRate(exchangeRate);

        return int256(exchangeRate);
    }
}
