methods {
    getBitNumFromMaturity(uint256 blockTime, uint256 maturity) returns (uint256, bool) envfree
    getMaturityFromBitNum(uint256 blockTime, uint256 bitNum) returns (uint256) envfree
    isValidMaturity(uint256 maxMarketIndex, uint256 maturity, uint256 blockTime) returns (bool) envfree
    getMarketIndex(uint256 maxMarketIndex, uint256 maturity, uint256 blockTime) returns (uint256, bool) envfree
    isValidMarketMaturity(uint256 maxMarketIndex, uint256 maturity, uint256 blockTime) returns (bool) envfree
}

definition MAX_TIMESTAMP() returns uint256 = 2^32 - 1;
// Cannot have timestamps less than 90 days
definition MIN_TIMESTAMP() returns uint256 = 7776000;
definition MIN_MARKET_INDEX() returns uint256 = 1;
definition MAX_MARKET_INDEX() returns uint256 = 7;
// 20 Years past the block time is the max maturity
definition MAX_MARKET_MATURITY(uint256 blockTime) returns uint256 = blockTime + 20 * 86400 * 360;

/**
 * The getBitNumFromMaturity and getMaturityFromBitNum methods must be inverses of each other given the
 * same blockTime.
 */
rule bitNumAndMaturitiesMustMatch(
    uint256 blockTime,
    uint256 maturity
) {
    // Respect time boundaries
    require MIN_TIMESTAMP() <= blockTime && blockTime <= MAX_TIMESTAMP();
    require MIN_TIMESTAMP() <= maturity && maturity <= MAX_TIMESTAMP();

    bool isValid = isValidMaturity(MAX_MARKET_INDEX(), maturity, blockTime);
    uint256 bitNum;
    bool isExact;
    bitNum, isExact = getBitNumFromMaturity(blockTime, maturity);

    // BitNums go out a bit past the max 20 year maturity, those bits are not valid
    assert isValid <=> (isExact && maturity <= MAX_MARKET_MATURITY(blockTime)), "bitnum is valid does not match is valid maturity";

    uint256 calculatedMaturity = getMaturityFromBitNum(blockTime, bitNum);
    // If the bitnum is not exact then the calculated maturity will not match
    assert isExact => maturity == calculatedMaturity, "maturity does not match calculated maturity";
}

/**
 * Verify that maturity methods are consistent with one another
 */
rule validMarketMaturitesHaveAnIndex(
    uint256 maxMarketIndex,
    uint256 maturity,
    uint256 blockTime
) {
    // Respect time boundaries
    require MIN_TIMESTAMP() <= blockTime && blockTime <= MAX_TIMESTAMP();
    require MIN_TIMESTAMP() <= maturity && maturity <= MAX_TIMESTAMP();
    require MIN_MARKET_INDEX() <= maxMarketIndex && maxMarketIndex <= MAX_MARKET_INDEX();

    bool isValid = isValidMaturity(maxMarketIndex, maturity, blockTime);
    uint256 marketIndex;
    bool isOnMarketIndex;
    marketIndex, isOnMarketIndex = getMarketIndex@withrevert(maxMarketIndex, maturity, blockTime);
    assert !isValid => lastReverted, "getMarketIndex did not revert on invalid maturity";

    bool isValidMarket = isValidMarketMaturity(maxMarketIndex, maturity, blockTime);
    // If a market is a valid market maturity then the getMarketIndex should agree
    assert isValidMarket <=> isOnMarketIndex, "is valid market does not imply a market index";
    assert MIN_MARKET_INDEX() <= marketIndex && marketIndex <= MAX_MARKET_INDEX(), "market index out of boundaries";
}