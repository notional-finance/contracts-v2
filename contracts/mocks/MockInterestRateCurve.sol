// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/markets/InterestRateCurve.sol";

contract MockInterestRateCurve {

    function getPrimeCashInterestRateParameters(
        uint16 currencyId
    ) external view returns (InterestRateParameters memory i) {
        return InterestRateCurve.getPrimeCashInterestRateParameters(currencyId);
    }

    function setPrimeCashInterestRateParameters(
        uint16 currencyId,
        InterestRateCurveSettings calldata settings
    ) external {
        return InterestRateCurve.setPrimeCashInterestRateParameters(currencyId, settings);
    }

    function setNextInterestRateParameters(
        uint16 currencyId,
        uint256 marketIndex,
        InterestRateCurveSettings calldata settings
    ) external {
        InterestRateCurve.setNextInterestRateParameters(currencyId, marketIndex, settings);
    }

    function getActiveInterestRateParameters(
        uint16 currencyId,
        uint8 marketIndex
    ) external view returns (InterestRateParameters memory i) {
        return InterestRateCurve.getActiveInterestRateParameters(currencyId, marketIndex);
    }

    function getNextInterestRateParameters(
        uint16 currencyId,
        uint8 marketIndex
    ) external view returns (InterestRateParameters memory i) {
        return InterestRateCurve.getNextInterestRateParameters(currencyId, marketIndex);
    }

    function setActiveInterestRateParameters(uint16 currencyId) external {
        InterestRateCurve.setActiveInterestRateParameters(currencyId);
    }

    function getInterestRates(
        uint16 currencyId,
        uint8 marketIndex,
        bool isBorrow,
        uint256 utilization
    ) external view returns (uint256 preFeeInterestRate, uint256 postFeeInterestRate) {
        InterestRateParameters memory irParams = InterestRateCurve.getActiveInterestRateParameters(
            currencyId, marketIndex
        );

        preFeeInterestRate = InterestRateCurve.getInterestRate(irParams, utilization);
        postFeeInterestRate = InterestRateCurve.getPostFeeInterestRate(irParams, preFeeInterestRate, isBorrow);
    }

    function getUtilizationFromInterestRate(
        uint16 currencyId,
        uint8 marketIndex,
        uint256 interestRate
    ) external view returns (uint256 utilization) {
        InterestRateParameters memory irParams = InterestRateCurve.getActiveInterestRateParameters(
            currencyId, marketIndex
        );

        return InterestRateCurve.getUtilizationFromInterestRate(irParams, interestRate);
    }
}