// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../global/LibStorage.sol";
import "../internal/nToken/nTokenHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * @notice Deployed library for migration of incentives from the old (inaccurate) calculation
 * to a newer, more accurate calculation based on SushiSwap MasterChef math. The more accurate
 * calculation is inside `Incentives.sol` and this library holds the legacy calculation. System
 * migration code can be found in `MigrateIncentivesFix.sol`
 */
library MigrateIncentives {
    using SafeMath for uint256;

    /// @notice Calculates the claimable incentives for a particular nToken and account in the
    /// previous regime. This should only ever be called ONCE for an account / currency combination
    /// to get the incentives accrued up until the migration date.
    function migrateAccountFromPreviousCalculation(
        address tokenAddress,
        uint256 nTokenBalance,
        uint256 lastClaimTime,
        uint256 lastClaimIntegralSupply
    ) external view returns (uint256) {
        (
            uint256 finalEmissionRatePerYear,
            uint256 finalTotalIntegralSupply,
            uint256 finalMigrationTime
        ) = _getMigratedIncentiveValues(tokenAddress);

        // This if statement should never be true but we return 0 just in case
        if (lastClaimTime == 0 || lastClaimTime >= finalMigrationTime) return 0;

        // No overflow here, checked above. All incentives are claimed up until finalMigrationTime
        // using the finalTotalIntegralSupply. Both these values are set on migration and will not
        // change.
        uint256 timeSinceMigration = finalMigrationTime - lastClaimTime;

        // (timeSinceMigration * INTERNAL_TOKEN_PRECISION * finalEmissionRatePerYear) / YEAR
        uint256 incentiveRate =
            timeSinceMigration
                .mul(uint256(Constants.INTERNAL_TOKEN_PRECISION))
                // Migration emission rate is stored as is, denominated in whole tokens
                .mul(finalEmissionRatePerYear).mul(uint256(Constants.INTERNAL_TOKEN_PRECISION))
                .div(Constants.YEAR);

        // Returns the average supply using the integral of the total supply.
        uint256 avgTotalSupply = finalTotalIntegralSupply.sub(lastClaimIntegralSupply).div(timeSinceMigration);
        if (avgTotalSupply == 0) return 0;

        uint256 incentivesToClaim = nTokenBalance.mul(incentiveRate).div(avgTotalSupply);
        // incentiveRate has a decimal basis of 1e16 so divide by token precision to reduce to 1e8
        incentivesToClaim = incentivesToClaim.div(uint256(Constants.INTERNAL_TOKEN_PRECISION));

        return incentivesToClaim;
    }

    function _getMigratedIncentiveValues(
        address tokenAddress
    ) private view returns (
        uint256 finalEmissionRatePerYear,
        uint256 finalTotalIntegralSupply,
        uint256 finalMigrationTime
    ) {
        mapping(address => nTokenTotalSupplyStorage_deprecated) storage store = LibStorage.getDeprecatedNTokenTotalSupplyStorage();
        nTokenTotalSupplyStorage_deprecated storage d_nTokenStorage = store[tokenAddress];

        // The total supply value is overridden as emissionRatePerYear during the initialization
        finalEmissionRatePerYear = d_nTokenStorage.totalSupply;
        finalTotalIntegralSupply = d_nTokenStorage.integralTotalSupply;
        finalMigrationTime = d_nTokenStorage.lastSupplyChangeTime;
    }

}