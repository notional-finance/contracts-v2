// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./TokenHandler.sol";
import "../nTokenHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library Incentives {
    using SafeMath for uint256;

    /// @dev Notional incentivizes nTokens using the formula:
    ///     incentivesToClaim = (tokenBalance / totalSupply) * emissionRatePerYear * proRataYears
    ///     where proRataYears is:
    ///         (timeSinceLastClaim / YEAR) * INTERNAL_TOKEN_PRECISION
    /// @return (emissionRatePerYear * proRataYears), decimal basis is (1e8 * 1e8 = 1e16)
    function _getIncentiveRate(uint256 timeSinceLastClaim, uint256 emissionRatePerYear)
        private
        pure
        returns (uint256)
    {
        // (timeSinceLastClaim * INTERNAL_TOKEN_PRECISION) / YEAR
        uint256 proRataYears =
            timeSinceLastClaim.mul(uint256(Constants.INTERNAL_TOKEN_PRECISION)).div(Constants.YEAR);

        return proRataYears.mul(emissionRatePerYear);
    }

    /// @notice Calculates the claimable incentives for a particular nToken and account
    function calculateIncentivesToClaim(
        address tokenAddress,
        uint256 nTokenBalance,
        uint256 lastClaimTime,
        uint256 lastClaimSupply,
        uint256 blockTime
    ) internal view returns (uint256, uint256) {
        // prettier-ignore
        (
            /* currencyId */,
            uint256 totalSupply,
            uint256 emissionRatePerYear,
            /* initializedTime */,
            /* parameters */
        ) = nTokenHandler.getNTokenContext(tokenAddress);

        if (lastClaimTime == 0 || lastClaimTime >= blockTime) return (0, totalSupply);
        if (totalSupply == 0) return (0, 0);

        uint256 incentiveRate =
            _getIncentiveRate(
                // No overflow here, checked above
                blockTime - lastClaimTime,
                // Convert this to the appropriate denomination
                emissionRatePerYear.mul(uint256(Constants.INTERNAL_TOKEN_PRECISION))
            );

        // Returns the average supply between now and the previous mint time. This is done to dampen the effect of
        // total supply fluctuations when claiming tokens. For example, if someone minted nTokens when the supply was
        // at 100e8 and then claimed incentives when the supply was at 100_000e8, they would be diluted out of part of
        // their token incentives. This will ensure that they claim with an average supply of 50_050e8, which is better
        // than not doing the average
        uint256 avgTotalSupply =
            totalSupply.add(lastClaimSupply.mul(uint256(Constants.INTERNAL_TOKEN_PRECISION))).div(
                2
            );

        uint256 incentivesToClaim = nTokenBalance.mul(incentiveRate).div(avgTotalSupply);
        incentivesToClaim = incentivesToClaim.div(uint256(Constants.INTERNAL_TOKEN_PRECISION));

        return (incentivesToClaim, totalSupply);
    }

    /// @notice Incentives must be claimed every time nToken balance changes
    function claimIncentives(BalanceState memory balanceState, address account)
        internal
        returns (uint256)
    {
        uint256 blockTime = block.timestamp;
        address tokenAddress = nTokenHandler.nTokenAddress(balanceState.currencyId);
        uint256 totalSupply;
        uint256 incentivesToClaim;

        (incentivesToClaim, totalSupply) = calculateIncentivesToClaim(
            tokenAddress,
            uint256(balanceState.storedNTokenBalance),
            balanceState.lastClaimTime,
            balanceState.lastClaimSupply,
            blockTime
        );
        balanceState.lastClaimTime = blockTime;

        if (incentivesToClaim > 0) TokenHandler.transferIncentive(account, incentivesToClaim);

        // Change the supply amount after incentives have been claimed
        if (balanceState.netNTokenSupplyChange != 0) {
            totalSupply = nTokenHandler.changeNTokenSupply(
                tokenAddress,
                balanceState.netNTokenSupplyChange
            );
        }

        // Trim off decimal places when storing the last claim supply for storage efficiency
        balanceState.lastClaimSupply = totalSupply.div(uint256(Constants.INTERNAL_TOKEN_PRECISION));

        return incentivesToClaim;
    }
}
