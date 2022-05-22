// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import {
    StakedNTokenSupply,
    StakedNTokenSupplyStorage,
    StakedNTokenIncentivesStorage
} from "../../../global/Types.sol";
import {Constants} from "../../../global/Constants.sol";
import {nTokenSupply} from "../nTokenSupply.sol";
import {nTokenHandler} from "../nTokenHandler.sol";
import {LibStorage} from "../../../global/LibStorage.sol";

import {SafeInt256} from "../../../math/SafeInt256.sol";
import {SafeUint256} from "../../../math/SafeUint256.sol";

library StakedNTokenSupplyLib {
    using SafeUint256 for uint256;

    /// @notice Gets the current staked nToken supply
    function getStakedNTokenSupply(uint16 currencyId) internal view returns (StakedNTokenSupply memory stakedSupply) {
        mapping(uint256 => StakedNTokenSupplyStorage) storage store = LibStorage.getStakedNTokenSupply();
        StakedNTokenSupplyStorage storage s = store[currencyId];

        stakedSupply.totalSupply = s.totalSupply;
        stakedSupply.nTokenBalance = s.nTokenBalance;
        stakedSupply.totalCashProfits = s.totalCashProfits;
    }

    function setStakedNTokenSupply(StakedNTokenSupply memory stakedSupply, uint16 currencyId) internal {
        mapping(uint256 => StakedNTokenSupplyStorage) storage store = LibStorage.getStakedNTokenSupply();
        StakedNTokenSupplyStorage storage s = store[currencyId];

        s.totalSupply = stakedSupply.totalSupply.toUint88();
        s.nTokenBalance = stakedSupply.nTokenBalance.toUint88();
        s.totalCashProfits = stakedSupply.totalCashProfits.toUint80();
    }

    /// @notice This can only be called by governance to update the emission rate for staked nTokens
    function setStakedNTokenEmissions(
        uint16 currencyId,
        uint32 totalAnnualStakedEmission,
        uint32 blockTime
    ) internal {
        // No nToken supply change
        updateAccumulatedNOTE(getStakedNTokenSupply(currencyId), currencyId, blockTime, 0);

        mapping(uint256 => StakedNTokenIncentivesStorage) storage store = LibStorage.getStakedNTokenIncentives();
        StakedNTokenIncentivesStorage storage s = store[currencyId];

        // Sanity check that emissions rate is not specified in 1e8 terms.
        require(totalAnnualStakedEmission < Constants.INTERNAL_TOKEN_PRECISION, "Invalid rate");
        s.totalAnnualStakedEmission = totalAnnualStakedEmission;
    }

    /**
     * Updates the accumulated NOTE incentives globally. Staked nTokens earn NOTE incentives through two
     * channels:
     *  - baseNOTEPerStaked: these are NOTE incentives accumulated to all nToken holders, regardless
     *    of staking status. They are computed using the accumulatedNOTEPerNToken figure calculated in nTokenSupply.
     *    The source of these incentives are the nTokens held by the staked nToken account.
     *  - additionalNOTEPerStaked: these are additional NOTE incentives that only accumulate to staked nToken holders,
     *    This is calculated based on the totalStakedEmission and the supply of staked nTokens.
     *
     * @param currencyId id of the currency
     * @param blockTime current block time
     * @param stakedSupply has its accumulators updated in memory
     * @param netNTokenSupplyChange amount of nTokens supply change
     */
    function updateAccumulatedNOTE(
        StakedNTokenSupply memory stakedSupply,
        uint16 currencyId,
        uint256 blockTime,
        int256 netNTokenSupplyChange
    ) internal returns (uint256 accumulatedNOTE) {
        mapping(uint256 => StakedNTokenIncentivesStorage) storage store = LibStorage.getStakedNTokenIncentives();
        StakedNTokenIncentivesStorage storage s = store[currencyId];

        // Read these values from storage
        uint256 lastAccumulatedTime = s.lastAccumulatedTime;
        uint256 totalAnnualStakedEmission = s.totalAnnualStakedEmission;
        uint256 totalAccumulatedNOTEPerStaked = s.totalAccumulatedNOTEPerStaked;
        uint256 lastBaseAccumulatedNOTEPerNToken = s.lastBaseAccumulatedNOTEPerNToken;

        // Update the accumulators from the underlying nTokens accumulated
        (
            uint256 baseNOTEPerStaked,
            uint256 baseAccumulatedNOTEPerNToken
        ) = _updateBaseAccumulatedNOTE(
            stakedSupply, currencyId, blockTime, lastBaseAccumulatedNOTEPerNToken, netNTokenSupplyChange
        );

        // Uses the same calculation from the nToken to determine how many additional NOTEs to emit
        // to snToken holders.
        uint256 additionalNOTEPerStaked = nTokenSupply.calculateAdditionalNOTEPerSupply(
            stakedSupply.totalSupply,
            lastAccumulatedTime,
            totalAnnualStakedEmission,
            blockTime
        );

        totalAccumulatedNOTEPerStaked = totalAccumulatedNOTEPerStaked.add(baseNOTEPerStaked).add(additionalNOTEPerStaked);

        // Update the incentives in storage
        s.lastAccumulatedTime = blockTime.toUint32();
        s.totalAccumulatedNOTEPerStaked = totalAccumulatedNOTEPerStaked.toUint112();
        s.lastBaseAccumulatedNOTEPerNToken = baseAccumulatedNOTEPerNToken.toUint112();
    }

    /**
     * @notice baseAccumulatedNOTEPerStaked needs to be updated every time either the nTokenBalance
     * or totalSupply of staked NOTE changes. Also accumulates incentives on the nToken.
     * @dev Updates the stakedSupply memory object but does not set storage.
     * @param stakedSupply variables that apply to the sNToken supply
     * @param currencyId currency id of the nToken
     * @param blockTime current block time
     * @param netNTokenSupplyChange passed into the changeNTokenSupply method in the case that the totalSupply
     * of nTokens has changed, this has no effect on the current accumulated NOTE
     * @return baseNOTEPerStaked the underlying incentives to the nToken rebased for the staked nToken supply
     * @return baseAccumulatedNOTEPerNToken stored as a reference for updating the snToken accumulator
     */
    function _updateBaseAccumulatedNOTE(
        StakedNTokenSupply memory stakedSupply,
        uint16 currencyId,
        uint256 blockTime,
        uint256 lastBaseAccumulatedNOTEPerNToken,
        int256 netNTokenSupplyChange
    ) private returns (
        uint256 baseNOTEPerStaked,
        uint256 baseAccumulatedNOTEPerNToken
    ) {
        address nTokenAddress = nTokenHandler.nTokenAddress(currencyId);
        // This will get the most current accumulated NOTE Per nToken.
        baseAccumulatedNOTEPerNToken = nTokenSupply.changeNTokenSupply(nTokenAddress, netNTokenSupplyChange, blockTime);

        // The accumulator is always increasing, therefore this value should always be greater than or equal
        // to zero.
        uint256 increaseInAccumulatedNOTE = baseAccumulatedNOTEPerNToken.sub(lastBaseAccumulatedNOTEPerNToken);
        
        if (stakedSupply.totalSupply > 0) {
            // Convert the increase from a perNToken basis to a per sNToken basis:
            // (NOTE / nToken) * (nToken / sNToken) = NOTE / sNToken
            baseNOTEPerStaked = increaseInAccumulatedNOTE
                .mul(stakedSupply.nTokenBalance)
                .div(stakedSupply.totalSupply);
        }
    }
}