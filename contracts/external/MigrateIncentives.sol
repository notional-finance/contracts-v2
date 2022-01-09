// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../global/LibStorage.sol";
import "../internal/nToken/nTokenHandler.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * @notice Deployed library for migration of incentives from the old (inaccurate) calculation
 * to a newer, more accurate calculation based on SushiSwap MasterChef math. The more accurate
 * calculation is inside `Incentives.sol` and this library holds the legacy calculation as well
 * as the system migration code to be called once.
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
        if (lastClaimTime == 0 || lastClaimTime > finalMigrationTime) return 0;

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

    /// @notice Can only be called via Governance one time per nToken to migrate the incentive calculation to the
    /// new regime. Stores off the old incentive factors at the specified block time and then initializes the new
    /// incentive factors.
    function migrateNTokenToNewIncentive(
        address tokenAddress,
        uint256 blockTime
    ) external {
        mapping(address => nTokenTotalSupplyStorage_deprecated) storage store = LibStorage.getDeprecatedNTokenTotalSupplyStorage();
        nTokenTotalSupplyStorage_deprecated storage d_nTokenStorage = store[tokenAddress];

        uint256 totalSupply = d_nTokenStorage.totalSupply;
        uint256 integralTotalSupply = d_nTokenStorage.integralTotalSupply;
        uint256 lastSupplyChangeTime = d_nTokenStorage.lastSupplyChangeTime;

        // Set up the new storage slot
        _initializeNewSupplyStorage(tokenAddress, totalSupply, blockTime);

        integralTotalSupply = _calculateFinalIntegralTotalSupply(
            totalSupply,
            integralTotalSupply,
            lastSupplyChangeTime,
            blockTime
        );

        // prettier-ignore
        (
            /* currencyId */,
            uint256 emissionRatePerYear,
            /* initializedTime */,
            /* assetArrayLength */,
            /* parameters */
        ) = nTokenHandler.getNTokenContext(tokenAddress);
        require(emissionRatePerYear <= type(uint96).max);

        // Now we store the final integral total supply and the migration emission rate after this these values
        // will not change. Override the totalSupply to store the emissionRatePerYear at this point. We will not
        // use the totalSupply after this.
        d_nTokenStorage.totalSupply = uint96(emissionRatePerYear);
        // Overflows checked in _calculateFinalIntegralSupply
        d_nTokenStorage.integralTotalSupply = uint128(integralTotalSupply);
        d_nTokenStorage.lastSupplyChangeTime = uint32(blockTime);
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

    function _initializeNewSupplyStorage(
        address tokenAddress,
        uint256 totalSupply,
        uint256 blockTime
    ) private {
        mapping(address => nTokenTotalSupplyStorage) storage store = LibStorage.getNTokenTotalSupplyStorage();
        nTokenTotalSupplyStorage storage nTokenStorage = store[tokenAddress];
        uint96 _totalSupply = nTokenStorage.totalSupply;
        uint256 _accumulatedNOTEPerNToken = nTokenStorage.accumulatedNOTEPerNToken;
        uint256 _lastAccumulatedTime = nTokenStorage.lastAccumulatedTime;

        // Storage must be zero'd out, we cannot re-initialize this slot once done
        require(_totalSupply == 0 && _accumulatedNOTEPerNToken == 0 && _lastAccumulatedTime == 0);

        require(totalSupply <= type(uint96).max);
        require(blockTime <= type(uint32).max);
        nTokenStorage.totalSupply = uint96(totalSupply);
        nTokenStorage.lastAccumulatedTime = uint32(blockTime);
    }

    function _calculateFinalIntegralTotalSupply(
        uint256 totalSupply,
        uint256 integralTotalSupply,
        uint256 lastSupplyChangeTime,
        uint256 blockTime
    ) private pure returns (uint256) {
        // Initialize last supply change time if it has not been set.
        if (lastSupplyChangeTime == 0) lastSupplyChangeTime = blockTime;
        require(blockTime >= lastSupplyChangeTime); // dev: invalid block time

        // Add to the integral total supply the total supply of tokens multiplied by the time that the total supply
        // has been the value. This will part of the numerator for the average total supply calculation during
        // minting incentives.
        integralTotalSupply = integralTotalSupply.add(totalSupply.mul(blockTime - lastSupplyChangeTime));

        require(integralTotalSupply >= 0 && integralTotalSupply < type(uint128).max); // dev: integral total supply overflow
        require(blockTime < type(uint32).max); // dev: last supply change supply overflow

        return integralTotalSupply;
    }

}