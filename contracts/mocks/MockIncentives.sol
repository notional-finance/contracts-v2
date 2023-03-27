// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/balances/Incentives.sol";
import "../internal/nToken/nTokenHandler.sol";
import "../internal/nToken/nTokenSupply.sol";
import "../external/MigrateIncentives.sol";
import "../external/patchfix/MigrateIncentivesFix.sol";
import "../global/LibStorage.sol";

contract MockIncentives {
    event ClaimRewards(
        address account,
        uint256 nTokenBalanceBefore,
        uint256 nTokenBalanceAfter,
        uint256 NOTETokensClaimed
    );

    function setNTokenAddress(uint16 currencyId, address tokenAddress) external {
        nTokenHandler.setNTokenAddress(currencyId, tokenAddress);
    }

    function setEmissionRateDirect(address tokenAddress, uint32 emissionRate) external {
        mapping(address => nTokenContext) storage store = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = store[tokenAddress];
        context.incentiveAnnualEmissionRate = emissionRate;
    }

    function setEmissionRate(
        address tokenAddress,
        uint32 emissionRate,
        uint32 blockTime
    ) external {
        nTokenSupply.setIncentiveEmissionRate(tokenAddress, emissionRate, blockTime);
    }

    function changeNTokenSupply(
        address tokenAddress,
        int256 totalSupply,
        uint32 blockTime
    ) external returns (uint256) {
        return nTokenSupply.changeNTokenSupply(tokenAddress, totalSupply, blockTime);
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
        return nTokenSupply.getStoredNTokenSupplyFactors(tokenAddress);
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
        mapping(address => nTokenTotalSupplyStorage_deprecated) storage store = LibStorage
            .getDeprecatedNTokenTotalSupplyStorage();
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
        mapping(address => nTokenTotalSupplyStorage_deprecated) storage store = LibStorage
            .getDeprecatedNTokenTotalSupplyStorage();
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
        ) = nTokenSupply.getUpdatedAccumulatedNOTEPerNToken(tokenAddress, blockTime);

        incentivesToClaim = Incentives.calculateIncentivesToClaim(
            balanceState,
            tokenAddress,
            accumulatedNOTEPerNToken,
            finalNTokenBalance
        );

        return (incentivesToClaim, balanceState);
    }

    function claimIncentives(
        BalanceState memory balanceState,
        address account,
        uint256 finalNTokenBalance
    ) external returns (uint256 incentivesToClaim) {
        return Incentives.claimIncentives(balanceState, account, finalNTokenBalance);
    }

    function migrateNToken(uint16 currencyId, uint256 blockTime) external {
        MigrateIncentivesLib._migrateIncentives(currencyId, blockTime);
    }

    function setSecondaryRewarder(uint16 currencyId, IRewarder rewarder) external {
        nTokenHandler.setSecondaryRewarder(currencyId, rewarder);
    }

    function getSecondaryRewarder(address tokenAddress) external view returns (IRewarder) {
        return nTokenHandler.getSecondaryRewarder(tokenAddress);
    }
}
