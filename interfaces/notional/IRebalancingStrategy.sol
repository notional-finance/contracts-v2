// SPDX-License-Identifier: GPL-v3
pragma solidity >=0.7.0;
pragma abicoder v2;

import {IPrimeCashHoldingsOracle, DepositData, RedeemData} from "./IPrimeCashHoldingsOracle.sol";

struct RebalancingData {
    RedeemData[] redeemData;
    DepositData[] depositData;
}

interface IRebalancingStrategy {
    function calculateRebalance(
        IPrimeCashHoldingsOracle oracle, 
        uint8[] calldata rebalancingTargets
    ) external view returns (RebalancingData memory rebalancingData);
}
