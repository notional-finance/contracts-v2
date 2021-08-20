// Fail: don't understand
// https://vaas-stg.certora.com/output/42394/e59dddb7999e21ae7ff1/?anonymousKey=0fcd3041c4d1fcabbb579c35e20162c6dde259b8
rule incentivesClaimedIncreaseLinearlyWithTime(
    address tokenAddress,
    uint256 nTokenBalance,
    uint256 lastClaimTime,
    uint256 lastClaimIntegralSupply,
    uint256 integralTotalSupply,
    uint32 emissionRate,
    uint256 blockTime1,
    uint256 blockTime2,
    uint256 blockTime3
) {
    env e;
    require blockTime1 >= lastClaimTime;
    require blockTime2 > blockTime1;
    require blockTime3 > blockTime2;
    require blockTime3 < 2 ^ 40 - 1;
    require lastClaimIntegralSupply < integralTotalSupply;

    uint256 i1 = calculateIncentivesToClaim(
        e,
        tokenAddress,
        nTokenBalance,
        lastClaimTime,
        lastClaimIntegralSupply,
        blockTime1,
        integralTotalSupply,
        emissionRate
    );

    uint256 i2 = calculateIncentivesToClaim(
        e,
        tokenAddress,
        nTokenBalance,
        lastClaimTime,
        lastClaimIntegralSupply,
        blockTime2,
        integralTotalSupply,
        emissionRate
    );

    uint256 i3 = calculateIncentivesToClaim(
        e,
        tokenAddress,
        nTokenBalance,
        lastClaimTime,
        lastClaimIntegralSupply,
        blockTime3,
        integralTotalSupply,
        emissionRate
    );

    assert i1 <= i2;
    assert i2 <= i3;
    // Holding all else constant, incentives should increase linearly with time
    // (i2 - i1) == C * (blockTime2 - blockTime1)
    // (i3 - i1) == C * (blockTime3 - blockTime1)
    // => (i2 - i1) / (blockTime2 - blockTime1) == (i3 - i1) / (blockTime3 - blockTime1)
    // => (i2 - i1) * (i3 - i1) == (blockTime2 - blockTime1) * (blockTime3 - blockTime1)
    uint256 term = (i2 - i1) * (i3 - i1);
    assert term != 0 => term == (blockTime2 - blockTime1) * (blockTime3 - blockTime1);
}