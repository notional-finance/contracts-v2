// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../internal/balances/Incentives.sol";
import "../internal/nTokenHandler.sol";
import "../external/MigrateIncentives.sol";
import "../global/LibStorage.sol";

contract MockIncentives {
    function setNTokenAddress(
        uint16 currencyId,
        address tokenAddress
    ) external {
        nTokenHandler.setNTokenAddress(currencyId, tokenAddress);
    }

    function setEmissionRateDirect(
        address tokenAddress,
        uint32 emissionRate
    ) external {
        mapping(address => nTokenContext) storage store = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = store[tokenAddress];
        context.incentiveAnnualEmissionRate = emissionRate;
    }

    function setEmissionRate(
        address tokenAddress,
        uint32 emissionRate,
        uint32 blockTime
    ) external {
        nTokenHandler.setIncentiveEmissionRate(tokenAddress, emissionRate, blockTime);
    }

    function changeNTokenSupply(
        address tokenAddress,
        int256 totalSupply,
        uint32 blockTime
    ) external returns (uint256) {
        return nTokenHandler.changeNTokenSupply(tokenAddress, totalSupply, blockTime);
    }

    function getStoredNTokenSupplyFactors(address tokenAddress)
        external
        view
        returns (
            uint256 totalSupply,
            uint256 accumulatedNOTEPerNToken,
            uint256 lastAccumulatedTime
        )
    {
        return nTokenHandler.getStoredNTokenSupplyFactors(tokenAddress);
    }

    function getDeprecatedNTokenSupplyFactors(address tokenAddress)
        external
        view
        returns (
            uint256 emissionRate,
            uint256 integralTotalSupply,
            uint256 migrationTime
        )
    {
        mapping(address => nTokenTotalSupplyStorage_deprecated) storage store = LibStorage.getDeprecatedNTokenTotalSupplyStorage();
        nTokenTotalSupplyStorage_deprecated storage d_nTokenStorage = store[tokenAddress];

        emissionRate = d_nTokenStorage.totalSupply;
        integralTotalSupply = d_nTokenStorage.integralTotalSupply;
        migrationTime = d_nTokenStorage.lastSupplyChangeTime;
    }


    function setDeprecatedStorageValues(
        address tokenAddress,
        uint96 totalSupply,
        uint128 integralTotalSupply,
        uint32 lastSupplyChangeTime
    ) external {
        mapping(address => nTokenTotalSupplyStorage_deprecated) storage store = LibStorage.getDeprecatedNTokenTotalSupplyStorage();
        nTokenTotalSupplyStorage_deprecated storage d_nTokenStorage = store[tokenAddress];

        d_nTokenStorage.totalSupply = totalSupply;
        d_nTokenStorage.integralTotalSupply = integralTotalSupply;
        d_nTokenStorage.lastSupplyChangeTime = lastSupplyChangeTime;
    }

    function calculateIncentivesToClaim(
        address tokenAddress,
        BalanceState memory balanceState,
        uint256 blockTime,
        uint256 finalNTokenBalance
    ) external view returns (uint256 incentivesToClaim, BalanceState memory) {
        (
            /* uint256 totalSupply */,
            uint256 accumulatedNOTEPerNToken,
            /* uint256 lastAccumulatedTime */
        ) = nTokenHandler.getUpdatedAccumulatedNOTEPerNToken(tokenAddress, blockTime);

        incentivesToClaim = Incentives.calculateIncentivesToClaim(
            balanceState,
            tokenAddress,
            accumulatedNOTEPerNToken,
            finalNTokenBalance
        );

        return (incentivesToClaim, balanceState);
    }

    function migrateNToken(address tokenAddress, uint256 blockTime) external {
        MigrateIncentives.migrateNTokenToNewIncentive(tokenAddress, blockTime);
    }
}
