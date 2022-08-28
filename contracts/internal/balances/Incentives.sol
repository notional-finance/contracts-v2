// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./TokenHandler.sol";
import "../nToken/nTokenHandler.sol";
import "../nToken/nTokenSupply.sol";
import "../../math/SafeInt256.sol";
import "../../external/MigrateIncentives.sol";
import "../../../interfaces/notional/IRewarder.sol";
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
                // In this case the accountIncentiveDebt is stored as lastClaimIntegralSupply under
                // the old calculation
                balanceState.accountIncentiveDebt
            );

            // This marks the account as migrated and lastClaimTime will no longer be used
            balanceState.lastClaimTime = 0;
            // This value will be set immediately after this, set this to zero so that the calculation
            // establishes a new baseline.
            balanceState.accountIncentiveDebt = 0;
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
                .sub(balanceState.accountIncentiveDebt)
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
        balanceState.accountIncentiveDebt = finalNTokenBalance
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
        uint256 accumulatedNOTEPerNToken = nTokenSupply.changeNTokenSupply(
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

        // If a secondary incentive rewarder is set, then call it
        IRewarder rewarder = nTokenHandler.getSecondaryRewarder(tokenAddress);
        if (address(rewarder) != address(0)) {
            rewarder.claimRewards(
                account,
                balanceState.currencyId,
                // When this method is called from finalize, the storedNTokenBalance has not
                // been updated to finalNTokenBalance yet so this is the balance before the change.
                balanceState.storedNTokenBalance.toUint(),
                finalNTokenBalance,
                // When the rewarder is called, totalSupply has been updated already so may need to
                // adjust its calculation using the net supply change figure here. Supply change
                // may be zero when nTokens are transferred.
                balanceState.netNTokenSupplyChange,
                incentivesToClaim
            );
        }

        if (incentivesToClaim > 0) TokenHandler.transferIncentive(account, incentivesToClaim);
    }
}
