rule incentivesClaimedIncreaseLinearlyWithTime(
    address tokenAddress,
    uint256 nTokenBalance,
    uint256 lastClaimTime,
    uint256 lastClaimIntegralSupply,
    uint256 integralTotalSupply,
    uint256 blockTime,
    uint256 nextBlockTime,
    uint32 emissionRate
) {
    env e;
    require blockTime >= lastClaimTime;
    require blockTime < nextBlockTime;
    require nextBlockTime < 2 ^ 40 - 1;
    require lastClaimIntegralSupply < integralTotalSupply;

    uint256 incentives1 = calculateIncentivesToClaim(
        e,
        tokenAddress,
        nTokenBalance,
        lastClaimTime,
        lastClaimIntegralSupply,
        blockTime,
        integralTotalSupply,
        emissionRate
    );

    uint256 incentives2 = calculateIncentivesToClaim(
        e,
        tokenAddress,
        nTokenBalance,
        lastClaimTime,
        lastClaimIntegralSupply,
        nextBlockTime,
        integralTotalSupply,
        emissionRate
    );

    // TODO: Should be proportional to time...
    assert incentives1 < incentives2;
}