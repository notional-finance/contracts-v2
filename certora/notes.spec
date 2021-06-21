// need to write this directly into a rule or something?
definition convertToSignedInteger(uint256) returns mathint

/** Define storage hooks for invariant properties **/
definition unpackCashBalance(bytes32 b) returns int88
definition unpackNTokenBalance(bytes32 b) returns uint80
definition unpackLastClaimTime(bytes32 b) returns uint32
definition unpackLastClaimTotalSupply(bytes32 b) returns uint56

// Parameterized by currency id and account address
ghost nTokenBalances(uint16, address) returns uint80;
// Parameterized by currency id and account address
ghost accountCashBalances(uint16, address) returns int88;
// Parameterized by maturity, settlement date, and currency id
ghost marketCashBalances(uint32, uint32, uint16) returns uint80;

hook Sstore balances
    [KEY uint16 currencyId]
    [KEY address account]
    bytes32 b (bytes32 b_old) STORAGE {

    // int88 cashBalance_new = unpackCashBalance(b)
    // uint80 nTokenBalance_new = unpackNTokenBalance(b)
    // uint56 lastClaimTotalSupply_new = unpackLastClaimTotalSupply(b)
    uint32 lastClaimTime_new = unpackLastClaimTime(b)

    // int88 cashBalance_old = unpackCashBalance(b_old)
    // uint80 nTokenBalance_old = unpackNTokenBalance(b_old)
    // uint56 lastClaimTotalSupply_old = unpackLastClaimTotalSupply(b_old)
    uint32 lastClaimTime_old = unpackLastClaimTime(b_old)

    // Assert that last claim time increases whenever nTokenBalance changes
    havoc nTokenBalances assuming nTokenBalances@new(currencyId, account) != nTokenBalances@old(currencyId, account) &&
        // NOTE: it's possible that two transactions occur at the same block time so this 
        // can legitimately be equal to each other
        lastClaimTime_new >= lastClaimTime_old

    /// SHOULD BE IN A INVARIANT, rules will need to require an invariant
    // QUESTION: is something like this possible?
    uint80 totalNTokenSupply = nToken.totalSupply()
    assert ghostTotalNTokenSupply() == totalNTokenSupply
    /// SHOULD BE IN A INVARIANT


    havoc ghostTotalNTokenSupply assuming ghostTotalNTokenSupply@new == ghostTotalNTokenSupply@old + nTokenBalance_new - nTokenBalance_old
}

hook Sstore markets
    [KEY uint32 maturity]
    [KEY uint32 settlementDate]
    [KEY uint16 currencyId]
    bytes32 m_new (bytes32 m_old) STORAGE {
    
    uint80 totalfCash_new = unpackTotalfCash(m_new)
    uint80 totalAssetCash_new = unpackTotalAssetCash(m_new)
    uint256 totalLiquidity_new = unpackTotalLiquidity(m_new)

    uint80 totalfCash_old = unpackTotalfCash(m_old)
    uint80 totalAssetCash_old = unpackTotalAssetCash(m_old)
    uint256 totalLiquidity_old = unpackTotalLiquidity(m_old)

    // QUESTION: can i do something like this?
    // QUESTION: there's a type change from int88 to uint256...does that matter?
    uint256 totalAccountCashBalance = sum(forall address a. accountCashBalances(currencyId, a))
    uint256 totalMarketCashBalance = sum(forall uint32 m, uint32 s. marketCashBalances(m, s, currencyId))
    // This would be a contract method call
    uint256 totalSystemCashBalance = getTokenBalance(currencyId)
    assert (totalAccountCashBalance + totalMarketCashBalance) == totalSystemCashBalance
}