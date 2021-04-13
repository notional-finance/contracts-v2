// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./TokenHandler.sol";
import "../PerpetualToken.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library Incentives {
    using SafeMath for uint256;

    /// @notice Calculates the claimable incentives for a particular nToken and account
    function calculateIncentivesToClaim(
        address tokenAddress,
        uint256 nTokenBalance,
        uint256 lastClaimTime,
        uint256 blockTime
    ) internal view returns (uint256) {
        if (lastClaimTime == 0 || lastClaimTime >= blockTime) return 0;

        // prettier-ignore
        (
            /* currencyId */,
            uint256 totalSupply,
            uint256 incentiveAnnualEmissionRate,
            /* initializedTime */,
            /* parameters */
        ) = PerpetualToken.getPerpetualTokenContext(tokenAddress);
        if (totalSupply == 0) return 0;

        // No overflow here, checked above
        uint256 timeSinceLastClaim = blockTime - lastClaimTime;
        // nTokenBalance, totalSupply incentives are all in INTERNAL_TOKEN_PRECISION
        // timeSinceLastClaim and Constants.YEAR are both in seconds
        // TODO: emission rate is stored as uint32 so need a different basis here
        // incentiveAnnualEmissionRate is a per currency annualized rate in INTERNAL_TOKEN_PRECISION
        // tokenPrecision * seconds * tokenPrecision / (seconds * tokenPrecision)
        uint256 incentivesToClaim =
            nTokenBalance
                .mul(timeSinceLastClaim)
                .mul(uint256(Constants.INTERNAL_TOKEN_PRECISION))
                .mul(incentiveAnnualEmissionRate);

        incentivesToClaim = incentivesToClaim.div(Constants.YEAR).div(totalSupply);

        return incentivesToClaim;
    }

    /// @notice Incentives must be claimed every time nToken balance changes
    function claimIncentives(BalanceState memory balanceState, address account)
        internal
        returns (uint256)
    {
        uint256 blockTime = block.timestamp;
        address tokenAddress = PerpetualToken.nTokenAddress(balanceState.currencyId);

        uint256 incentivesToClaim =
            calculateIncentivesToClaim(
                tokenAddress,
                uint256(balanceState.storedPerpetualTokenBalance),
                balanceState.lastIncentiveClaim,
                blockTime
            );
        balanceState.lastIncentiveClaim = blockTime;
        if (incentivesToClaim > 0) TokenHandler.transferIncentive(account, incentivesToClaim);

        // Change the supply amount after incentives have been claimed
        if (balanceState.netPerpetualTokenSupplyChange != 0) {
            PerpetualToken.changePerpetualTokenSupply(
                tokenAddress,
                balanceState.netPerpetualTokenSupplyChange
            );
        }

        return incentivesToClaim;
    }
}
