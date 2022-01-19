// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./TokenHandler.sol";
import "../nTokenHandler.sol";
import "../../math/SafeInt256.sol";
import "../../external/MigrateIncentives.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library Incentives {
    using SafeMath for uint256;
    using SafeInt256 for int256;

    /// @notice Calculates the total incentives to claim including those claimed under the previous
    /// less accurate calculation. Once an account is migrated it will only claim incentives under
    /// the more accurate regime
    function calculateIncentivesToClaim(
        BalanceState memory balanceState,
        address tokenAddress,
        uint256 accumulatedNOTEPerNToken,
        uint256 finalNTokenBalance
    ) internal view returns (uint256 incentivesToClaim) {
        if (balanceState.lastClaimTime > 0) {
            // If lastClaimTime is set then the account had incentives under the
            // previous regime. Will calculate the final amount of incentives to claim here
            // under the previous regime.
            incentivesToClaim = MigrateIncentives.migrateAccountFromPreviousCalculation(
                tokenAddress,
                balanceState.storedNTokenBalance.toUint(),
                balanceState.lastClaimTime,
                balanceState.lastClaimIntegralSupply
            );

            // This marks the account as migrated and lastClaimTime will no longer be used
            balanceState.lastClaimTime = 0;
            balanceState.lastClaimIntegralSupply = 0;
        }

        // If an account was migrated then they have no accountIncentivesDebt and should accumulate
        // incentives based on their share since the new regime calculation started.
        // If an account is just initiating their nToken balance then storedNTokenBalance will be zero
        // and they will have no incentives to claim.
        // This calculation uses storedNTokenBalance which is the balance of the account up until this point,
        // this is important to ensure that the account does not claim for nTokens that they will mint or
        // redeem on a going forward basis.

        // The calculation below has the following precision:
        //   storedNTokenBalance (INTERNAL_TOKEN_PRECISION)
        //   MUL accumulatedNOTEPerNToken (INCENTIVE_ACCUMULATION_PRECISION)
        //   DIV INCENTIVE_ACCUMULATION_PRECISION
        //  = INTERNAL_TOKEN_PRECISION - (accountIncentivesDebt) INTERNAL_TOKEN_PRECISION
        incentivesToClaim = incentivesToClaim.add(
            balanceState.storedNTokenBalance.toUint()
                .mul(accumulatedNOTEPerNToken)
                .div(Constants.INCENTIVE_ACCUMULATION_PRECISION)
                // NOTE: This should be called accountIncentivesDebt
                .sub(balanceState.lastClaimIntegralSupply)
        );

        // Update accountIncentivesDebt denominated in INTERNAL_TOKEN_PRECISION which marks the portion
        // of the accumulatedNOTE that the account no longer has a claim over. Use the finalNTokenBalance
        // here instead of storedNTokenBalance to mark the overall incentives claim that the account
        // does not have a claim over. We do not aggregate this value with the previous accountIncentiveDebt
        // because accumulatedNOTEPerNToken is already an aggregated value.

        // The calculation below has the following precision:
        //   finalNTokenBalance (INTERNAL_TOKEN_PRECISION)
        //   MUL accumulatedNOTEPerNToken (INCENTIVE_ACCUMULATION_PRECISION)
        //   DIV INCENTIVE_ACCUMULATION_PRECISION
        //   = INTERNAL_TOKEN_PRECISION
        balanceState.lastClaimIntegralSupply = finalNTokenBalance
            .mul(accumulatedNOTEPerNToken)
            .div(Constants.INCENTIVE_ACCUMULATION_PRECISION);
    }

    /// @notice Incentives must be claimed every time nToken balance changes.
    /// @dev BalanceState.accountIncentiveDebt is updated in place here
    function claimIncentives(
        BalanceState memory balanceState,
        address account,
        uint256 finalNTokenBalance
    ) internal returns (uint256 incentivesToClaim) {
        uint256 blockTime = block.timestamp;
        address tokenAddress = nTokenHandler.nTokenAddress(balanceState.currencyId);
        // This will updated the nToken storage and return what the accumulatedNOTEPerNToken
        // is up until this current block time in 1e18 precision
        uint256 accumulatedNOTEPerNToken = nTokenHandler.changeNTokenSupply(
            tokenAddress,
            balanceState.netNTokenSupplyChange,
            blockTime
        );

        incentivesToClaim = calculateIncentivesToClaim(
            balanceState,
            tokenAddress,
            accumulatedNOTEPerNToken,
            finalNTokenBalance
        );

        if (incentivesToClaim > 0) TokenHandler.transferIncentive(account, incentivesToClaim);
    }
}
