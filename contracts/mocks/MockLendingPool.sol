// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../interfaces/aave/ILendingPool.sol";

contract MockLendingPool is ILendingPool {
    mapping(address => uint256) public reserveNormalizedIncome;
    mapping(address => uint128) public currentLiquidityRate;

    function setReserveNormalizedIncome(address asset, uint256 index) external {
        reserveNormalizedIncome[asset] = index;
    }

    function setCurrentLiquidityRate(address asset, uint128 rate) external {
        currentLiquidityRate[asset] = rate;
    }

    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external override {
        revert();
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external override returns (uint256) {
        revert();
    }
    
    function getReserveNormalizedIncome(address asset) external view override returns (uint256) {
        return reserveNormalizedIncome[asset];
    }

    function getReserveData(address asset) external view override returns (ReserveData memory) {
        ReserveData memory rd;
        rd.currentLiquidityRate = currentLiquidityRate[asset];
        return rd;
    }
}