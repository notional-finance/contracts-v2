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
    // alex : rule is proved without these preconditions:
    // require MIN_TIMESTAMP() <= blockTime && blockTime <= MAX_TIMESTAMP(); 
    // require MIN_TIMESTAMP() <= maturity && maturity <= MAX_TIMESTAMP();

    uint256 bitNum;
    bool isExact;
    bitNum, isExact = getBitNumFromMaturity(blockTime, maturity);
    uint256 calculatedMaturity = getMaturityFromBitNum(blockTime, bitNum);

    // If the bitnum is not exact then the calculated maturity will not match
    // alex: when dropping the antecedent, we get a violation --> good ; assert maturity == calculatedMaturity, "maturity does not match calculated maturity";
    assert isExact => maturity == calculatedMaturity, "maturity does not match calculated maturity";
}

/**
 * Any valid maturity must also be an exact bit number, meaning that any tradable market must be able
 * to be stored in the bitmap at that block time.
 */
rule bitNumValidMaturitiesMustBeExact(
    uint256 blockTime,
    uint256 maturity
) {
    // Respect time boundaries
    // alex: these two preconditions are needed
    require MIN_TIMESTAMP() <= blockTime && blockTime <= MAX_TIMESTAMP();
    require MIN_TIMESTAMP() <= maturity && maturity <= MAX_TIMESTAMP();
    // alex: this precondition is needed
    require isValidMaturity(MAX_MARKET_INDEX(), maturity, blockTime);
    bool isExact;
    _, isExact = getBitNumFromMaturity(blockTime, maturity);

    // BitNums go out a bit past the max 20 year maturity, those bits are not valid
    assert isExact && maturity <= MAX_MARKET_MATURITY(blockTime), "bitnum is valid does not match is valid maturity";
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
    // alex : rule is proved without these three preconditions:
    // require MIN_TIMESTAMP() <= blockTime && blockTime <= MAX_TIMESTAMP();
    // require MIN_TIMESTAMP() <= maturity && maturity <= MAX_TIMESTAMP();
    // require MIN_MARKET_INDEX() <= maxMarketIndex && maxMarketIndex <= MAX_MARKET_INDEX();

    uint256 marketIndex;
    bool isIdiosyncratic;
    marketIndex, isIdiosyncratic = getMarketIndex(maxMarketIndex, maturity, blockTime);
    bool isValidMarket = isValidMarketMaturity(maxMarketIndex, maturity, blockTime);

    // If a market is a valid market maturity then the getMarketIndex should agree
    // alex: flipping a flag here makes the rule fail (a good sign), e.g.: assert isValidMarket <=> isIdiosyncratic, "is valid market does not imply a market index";
    assert isValidMarket <=> !isIdiosyncratic, "is valid market does not imply a market index";
    // alex: making these intervals closed makes the rule fail (a good sign), e.g.: assert MIN_MARKET_INDEX() < marketIndex && marketIndex < MAX_MARKET_INDEX(), "market index out of boundaries";
    assert MIN_MARKET_INDEX() <= marketIndex && marketIndex <= MAX_MARKET_INDEX(), "market index out of boundaries";
}