// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../internal/balances/Incentives.sol";
import "../internal/nTokenHandler.sol";

contract MockIncentives {
    function setNTokenParameters(
        uint16 currencyId,
        address tokenAddress,
        int256 tokenSupply,
        uint32 emissionRate
    ) external {
        nTokenHandler.setNTokenAddress(currencyId, tokenAddress);
        nTokenHandler.changeNTokenSupply(tokenAddress, tokenSupply);
        nTokenHandler.setIncentiveEmissionRate(tokenAddress, emissionRate);
    }

    function calculateIncentivesToClaim(
        address tokenAddress,
        uint256 nTokenBalance,
        uint256 lastClaimTime,
        uint256 lastClaimSupply,
        uint256 blockTime
    ) external view returns (uint256) {
        (
            uint256 incentives, /* */

        ) =
            Incentives.calculateIncentivesToClaim(
                tokenAddress,
                nTokenBalance,
                lastClaimTime,
                lastClaimSupply,
                blockTime
            );

        return incentives;
    }
}
