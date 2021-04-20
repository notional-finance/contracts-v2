// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./TokenHandler.sol";
import "../nTokenHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library Incentives {
    using SafeMath for uint256;

    /// @dev Notional incentivizes long term holding of nTokens by adding a multiplier to the tokens
    /// accrued over time. The formula is:
    ///     incentivesToClaim = (tokenBalance / totalSupply) * emissionRatePerYear * proRataYears * multiplier
    ///     where multiplier is:
    ///         1 + (proRataYears * multiplierConstant)
    ///     and proRataYears is (timeSinceLastClaim / YEAR) * INTERNAL_TOKEN_PRECISION
    /// @return (emissionRatePerYear * proRataYears * multiplier), decimal basis is (1e8 * 1e8 * 1e8 = 1e24)
    function _getIncentiveMultiplier(uint256 timeSinceLastClaim, uint256 emissionRatePerYear)
        private
        pure
        returns (uint256)
    {
        // (timeSinceLastClaim * INTERNAL_TOKEN_PRECISION) / YEAR
        uint256 proRataYears =
            timeSinceLastClaim.mul(uint256(Constants.INTERNAL_TOKEN_PRECISION)).div(Constants.YEAR);

        // INTERNAL_TOKEN_PRECISION + (proRataYears * multiplierConstant)
        uint256 multiplier =
            proRataYears
                .mul(Constants.ANNUAL_INCENTIVE_MULTIPLIER_PERCENT)
                .div(uint256(Constants.PERCENTAGE_DECIMALS))
                .add(uint256(Constants.INTERNAL_TOKEN_PRECISION));

        // Cap the multiplier to some number of years so it does not accrue too aggressively
        if (multiplier > Constants.MAX_INCENTIVE_MULTIPLIER) {
            multiplier = Constants.MAX_INCENTIVE_MULTIPLIER;
        }

        return proRataYears.mul(multiplier).mul(emissionRatePerYear);
    }

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
            uint256 emissionRatePerYear,
            /* initializedTime */,
            /* parameters */
        ) = nTokenHandler.getNTokenContext(tokenAddress);
        if (totalSupply == 0) return 0;

        uint256 incentiveMultiplier =
            _getIncentiveMultiplier(
                // No overflow here, checked above
                blockTime - lastClaimTime,
                // Convert this to the appropriate denomination
                emissionRatePerYear.mul(uint256(Constants.INTERNAL_TOKEN_PRECISION))
            );

        uint256 incentivesToClaim =
            nTokenBalance
                .mul(incentiveMultiplier)
                .div(totalSupply)
                .div(uint256(Constants.INTERNAL_TOKEN_PRECISION))
                .div(uint256(Constants.INTERNAL_TOKEN_PRECISION));

        return incentivesToClaim;
    }

    /// @notice Incentives must be claimed every time nToken balance changes
    function claimIncentives(BalanceState memory balanceState, address account)
        internal
        returns (uint256)
    {
        uint256 blockTime = block.timestamp;
        address tokenAddress = nTokenHandler.nTokenAddress(balanceState.currencyId);

        uint256 incentivesToClaim =
            calculateIncentivesToClaim(
                tokenAddress,
                uint256(balanceState.storedNTokenBalance),
                balanceState.lastClaimTime,
                blockTime
            );
        balanceState.lastClaimTime = blockTime;

        if (incentivesToClaim > 0) TokenHandler.transferIncentive(account, incentivesToClaim);

        // Change the supply amount after incentives have been claimed
        if (balanceState.netNTokenSupplyChange != 0) {
            nTokenHandler.changeNTokenSupply(tokenAddress, balanceState.netNTokenSupplyChange);
        }

        return incentivesToClaim;
    }
}
