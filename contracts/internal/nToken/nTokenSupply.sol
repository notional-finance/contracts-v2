// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    nTokenTotalSupplyStorage,
    nTokenContext
} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {nTokenHandler} from "./nTokenHandler.sol";

library nTokenSupply {
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    /// @notice Retrieves stored nToken supply and related factors. Do not use accumulatedNOTEPerNToken for calculating
    /// incentives! Use `getUpdatedAccumulatedNOTEPerNToken` instead.
    function getStoredNTokenSupplyFactors(address tokenAddress)
        internal
        view
        returns (
            uint256 totalSupply,
            uint256 accumulatedNOTEPerNToken,
            uint256 lastAccumulatedTime
        )
    {
        mapping(address => nTokenTotalSupplyStorage) storage store = LibStorage.getNTokenTotalSupplyStorage();
        nTokenTotalSupplyStorage storage nTokenStorage = store[tokenAddress];
        totalSupply = nTokenStorage.totalSupply;
        // NOTE: DO NOT USE THIS RETURNED VALUE FOR CALCULATING INCENTIVES. The accumulatedNOTEPerNToken
        // must be updated given the block time. Use `getUpdatedAccumulatedNOTEPerNToken` instead
        accumulatedNOTEPerNToken = nTokenStorage.accumulatedNOTEPerNToken;
        lastAccumulatedTime = nTokenStorage.lastAccumulatedTime;
    }

    /// @notice Returns the updated accumulated NOTE per nToken for calculating incentives
    function getUpdatedAccumulatedNOTEPerNToken(address tokenAddress, uint256 blockTime)
        internal view
        returns (
            uint256 totalSupply,
            uint256 accumulatedNOTEPerNToken,
            uint256 lastAccumulatedTime
        )
    {
        (
            totalSupply,
            accumulatedNOTEPerNToken,
            lastAccumulatedTime
        ) = getStoredNTokenSupplyFactors(tokenAddress);

        // nToken totalSupply is never allowed to drop to zero but we check this here to avoid
        // divide by zero errors during initialization. Also ensure that lastAccumulatedTime is not
        // zero to avoid a massive accumulation amount on initialization.
        if (blockTime > lastAccumulatedTime && lastAccumulatedTime > 0 && totalSupply > 0) {
            // prettier-ignore
            (
                /* currencyId */,
                uint256 emissionRatePerYear,
                /* initializedTime */,
                /* assetArrayLength */,
                /* parameters */
            ) = nTokenHandler.getNTokenContext(tokenAddress);

            uint256 additionalNOTEAccumulatedPerNToken = _calculateAdditionalNOTE(
                // Emission rate is denominated in whole tokens, scale to 1e8 decimals here
                emissionRatePerYear.mul(uint256(Constants.INTERNAL_TOKEN_PRECISION)),
                // Time since last accumulation (overflow checked above)
                blockTime - lastAccumulatedTime,
                totalSupply
            );

            accumulatedNOTEPerNToken = accumulatedNOTEPerNToken.add(additionalNOTEAccumulatedPerNToken);
            require(accumulatedNOTEPerNToken < type(uint128).max); // dev: accumulated NOTE overflow
        }
    }

    /// @notice additionalNOTEPerNToken accumulated since last accumulation time in 1e18 precision
    function _calculateAdditionalNOTE(
        uint256 emissionRatePerYear,
        uint256 timeSinceLastAccumulation,
        uint256 totalSupply
    )
        private
        pure
        returns (uint256)
    {
        // If we use 18 decimal places as the accumulation precision then we will overflow uint128 when
        // a single nToken has accumulated 3.4 x 10^20 NOTE tokens. This isn't possible since the max
        // NOTE that can accumulate is 10^16 (100 million NOTE in 1e8 precision) so we should be safe
        // using 18 decimal places and uint128 storage slot

        // timeSinceLastAccumulation (SECONDS)
        // accumulatedNOTEPerSharePrecision (1e18)
        // emissionRatePerYear (INTERNAL_TOKEN_PRECISION)
        // DIVIDE BY
        // YEAR (SECONDS)
        // totalSupply (INTERNAL_TOKEN_PRECISION)
        return timeSinceLastAccumulation
            .mul(Constants.INCENTIVE_ACCUMULATION_PRECISION)
            .mul(emissionRatePerYear)
            .div(Constants.YEAR)
            // totalSupply > 0 is checked in the calling function
            .div(totalSupply);
    }

    /// @notice Updates the nToken token supply amount when minting or redeeming.
    /// @param tokenAddress address of the nToken
    /// @param netChange positive or negative change to the total nToken supply
    /// @param blockTime current block time
    /// @return accumulatedNOTEPerNToken updated to the given block time
    function changeNTokenSupply(
        address tokenAddress,
        int256 netChange,
        uint256 blockTime
    ) internal returns (uint256) {
        (
            uint256 totalSupply,
            uint256 accumulatedNOTEPerNToken,
            /* uint256 lastAccumulatedTime */
        ) = getUpdatedAccumulatedNOTEPerNToken(tokenAddress, blockTime);

        // Update storage variables
        mapping(address => nTokenTotalSupplyStorage) storage store = LibStorage.getNTokenTotalSupplyStorage();
        nTokenTotalSupplyStorage storage nTokenStorage = store[tokenAddress];

        int256 newTotalSupply = int256(totalSupply).add(netChange);
        // We allow newTotalSupply to equal zero here even though it is prevented from being redeemed down to
        // exactly zero by other internal logic inside nTokenRedeem. This is meant to be purely an overflow check.
        require(0 <= newTotalSupply && uint256(newTotalSupply) < type(uint96).max); // dev: nToken supply overflow

        nTokenStorage.totalSupply = uint96(newTotalSupply);
        // NOTE: overflow checked inside getUpdatedAccumulatedNOTEPerNToken so that behavior here mirrors what
        // the user would see if querying the view function
        nTokenStorage.accumulatedNOTEPerNToken = uint128(accumulatedNOTEPerNToken);

        require(blockTime < type(uint32).max); // dev: block time overflow
        nTokenStorage.lastAccumulatedTime = uint32(blockTime);

        return accumulatedNOTEPerNToken;
    }

    /// @notice Called by governance to set the new emission rate
    function setIncentiveEmissionRate(address tokenAddress, uint32 newEmissionsRate, uint256 blockTime) internal {
        // Ensure that the accumulatedNOTEPerNToken updates to the current block time before we update the
        // emission rate
        changeNTokenSupply(tokenAddress, 0, blockTime);

        mapping(address => nTokenContext) storage store = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = store[tokenAddress];
        context.incentiveAnnualEmissionRate = newEmissionsRate;
    }

}