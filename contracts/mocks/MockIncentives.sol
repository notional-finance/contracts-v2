// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../internal/balances/Incentives.sol";
import "../internal/nTokenHandler.sol";

contract MockIncentives {
    function setNTokenParameters(
        uint16 currencyId,
        address tokenAddress,
        int256 totalSupply,
        uint32 emissionRate,
        uint32 blockTime
    ) external returns (uint256) {
        nTokenHandler.setNTokenAddress(currencyId, tokenAddress);
        nTokenHandler.setIncentiveEmissionRate(tokenAddress, emissionRate, blockTime);
        return nTokenHandler.changeNTokenSupply(tokenAddress, totalSupply, blockTime);
    }

    function calculateIncentivesToClaim(
        address tokenAddress,
        BalanceState memory balanceState,
        uint256 blockTime
    ) external view returns (uint256 incentivesToClaim) {
        (
            /* uint256 totalSupply */,
            uint256 accumulatedNOTEPerNToken,
            /* uint256 lastAccumulatedTime */
        ) = nTokenHandler.getUpdatedAccumulatedNOTEPerNToken(tokenAddress, blockTime);

        incentivesToClaim = Incentives.calculateIncentivesToClaim(
            balanceState,
            tokenAddress,
            accumulatedNOTEPerNToken
        );
    }
}
