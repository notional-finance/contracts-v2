using MockAggregator as rateOracle;

methods {
    nTokenAddress(uint16 currencyId) returns (address) envfree;
    getNTokenAccount(address tokenAddress) returns (
        uint256 currencyId,
        uint256 totalSupply,
        uint256 incentiveAnnualEmissionRate,
        uint256 lastInitializedTime,
        bytes6 nTokenParameters,
        uint256 integralTotalSupply,
        uint256 lastSupplyChangeTime
    ) envfree;
    getNTokenParameters(address tokenAddress) returns (
        uint8 residualPurchaseIncentive10BPS,
        uint8 pvHaircutPercentage,
        uint8 residualPurchaseTimeBufferHours,
        uint8 cashWithholdingBuffer10BPS,
        uint8 liquidationHaircutPercentage,
        bytes6 x
    ) envfree;
    verifyDepositParameters(
        uint16 currencyId,
        uint32[] _depositShares,
        uint32[] _leverageThresholds
    ) returns (bool) envfree;
    verifyInitializationParameters(
        uint16 currencyId,
        uint32[] _annualizedAnchorRates,
        uint32[] _proportions
    ) returns (bool) envfree;
    getOwner() returns (address) envfree;

    getETHRate(uint16 currencyId) returns (
        int256 rateDecimals,
        int256 rate,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) envfree;

    latestRoundData() => CONSTANT;
    decimals() => ALWAYS(1);
}

// PASSES: 1753 seconds
rule updateDepositParametersSetsProperly(
    uint16 currencyId,
    uint32[] depositShares,
    uint32[] leverageThresholds
) {
    env e;
    require depositShares.length > 0 && depositShares.length <= 7;
    require leverageThresholds.length > 0 && leverageThresholds.length <= 7;
    updateDepositParameters(e, currencyId, depositShares, leverageThresholds);
    assert verifyDepositParameters(currencyId, depositShares, leverageThresholds);
}

// PASSES: 723 seconds
rule updateInitializationParametersSetsProperly(
    uint16 currencyId,
    uint32[] annualizedAnchorRates,
    uint32[] proportions
) {
    env e;
    require annualizedAnchorRates.length > 0 && annualizedAnchorRates.length <= 7;
    require proportions.length > 0 && proportions.length <= 7;
    updateInitializationParameters(e, currencyId, annualizedAnchorRates, proportions);
    assert verifyInitializationParameters(currencyId, annualizedAnchorRates, proportions);
}

// PASSES
rule updateIncentiveEmissionRateSetsProperly(
    uint16 currencyId,
    uint32 newEmissionRate,
    address tokenAddress 
) {
    env e;
    require nTokenAddress(currencyId) == tokenAddress;
    updateIncentiveEmissionRate(e, currencyId, newEmissionRate);
    uint256 incentiveEmissionRate;
    _, _, incentiveEmissionRate, _, _, _, _ = getNTokenAccount(tokenAddress);
    assert incentiveEmissionRate == newEmissionRate;
}

rule updateCollateralParametersSetsProperly(
    uint16 currencyId,
    uint8 residualPurchaseIncentive10BPS,
    uint8 pvHaircutPercentage,
    uint8 residualPurchaseTimeBufferHours,
    uint8 cashWithholdingBuffer10BPS,
    uint8 liquidationHaircutPercentage,
    address tokenAddress
) {
    env e;
    require nTokenAddress(currencyId) == tokenAddress;
    updateTokenCollateralParameters(
        e,
        currencyId,
        residualPurchaseIncentive10BPS,
        pvHaircutPercentage,
        residualPurchaseTimeBufferHours,
        cashWithholdingBuffer10BPS,
        liquidationHaircutPercentage
    );

    uint8 p1;
    uint8 p2;
    uint8 p3;
    uint8 p4;
    uint8 p5;
    bytes6 x;
    // TODO: is the tool grabbing the right byte from the array?
    p1, p2, p3, p4, p5, x = getNTokenParameters(tokenAddress);
    assert p1 == residualPurchaseIncentive10BPS;
    assert p2 == pvHaircutPercentage;
    assert p3 == residualPurchaseTimeBufferHours;
    assert p4 == cashWithholdingBuffer10BPS;
    assert p5 == liquidationHaircutPercentage;
}

// TODO: TIMEOUT
// https://vaas-stg.certora.com/output/42394/276bc7b0fd2b78b21847/?anonymousKey=e9a5f00c29157e36c1fa7b4d66e45dceaa3a9f88
rule cashGroupSetsProperly(
    uint16 currencyId,
    uint8 maxMarketIndex,
    uint8 rateOracleTimeWindowMin,
    uint8 totalFeeBPS,
    uint8 reserveFeeShare,
    uint8 debtBuffer5BPS,
    uint8 fCashHaircut5BPS,
    uint8 settlementPenaltyRate5BPS,
    uint8 liquidationfCashHaircut5BPS,
    uint8 liquidationDebtBuffer5BPS,
    uint8[] liquidityTokenHaircuts,
    uint8[] rateScalars
) {
    env e;
    // Allow the method below to call itself to use calldata.
    require getOwner() == currentContract;

    bool didVerify;
    didVerify = setCashGroupStorageAndVerify(
        e,
        currencyId,
        maxMarketIndex,
        rateOracleTimeWindowMin,
        totalFeeBPS,
        reserveFeeShare,
        debtBuffer5BPS,
        fCashHaircut5BPS,
        settlementPenaltyRate5BPS,
        liquidationfCashHaircut5BPS,
        liquidationDebtBuffer5BPS,
        liquidityTokenHaircuts,
        rateScalars
    );

    assert didVerify;
}

// // TODO
// rule updateETHRateSetsProperly(
//     uint16 currencyId,
//     address rateOracle,
//     bool mustInvert,
//     uint8 buffer,
//     uint8 haircut,
//     uint8 liquidationDiscount
// ) {
//     env e;
//     updateETHRate(
//         e,
//         currencyId,
//         rateOracle,
//         mustInvert,
//         buffer,
//         haircut,
//         liquidationDiscount
//     );

//     int256 _rateDecimals;
//     int256 _rate;
//     uint8 _buffer;
//     uint8 _haircut;
//     uint8 _liquidationDiscount;

//     // TODO: need to set up rate and rate decimals
//     _rateDecimals, _rate, _buffer, _haircut, _liquidationDiscount = getETHRate(currencyId);
//     // Special case for ETH
//     assert currencyId == 1 ? _rateDecimals == 10 ^ 18 : _rateDecimals == 10;
//     assert currencyId == 1 => _rate == 10 ^ 18;
//     assert currencyId != 1 && mustInvert => _rate == 100;
//     assert currencyId != 1 && !mustInvert => _rate == 1;

//     assert buffer == _buffer;
//     assert haircut == _haircut;
//     assert liquidationDiscount == _liquidationDiscount;
// }

// TODO
rule updateAssetRateSetsProperly(
    uint16 currencyId,
    address rateOracle
) {
    env e;
    updateAssetRate(e, currencyId, rateOracle);
    address _rateOracle;
    int256 rate;
    int256 underlyingDecimalPlaces;

    _rateOracle, rate, underlyingDecimalPlaces = getAssetRate(e, currencyId);

    assert _rateOracle == rateOracle;
    assert rateOracle == 0 => underlyingDecimalPlaces == 0 && rate == 10 ^ 10;
}

// TODO: setToken
rule listingCurrencySetsProperly(
    address assetToken,
    address underlyingToken,
    address rateOracle,
    bool mustInvert,
    uint8 buffer,
    uint8 haircut,
    uint8 liquidationDiscount
) {
    env e;
    require getMaxCurrencyId() >= 1;
    require assetToken != 0;
    require underlyingToken != 0;

    // TODO: need to put a harness here
    listCurrency(
        e,
        (assetToken, false, 1),
        (underlyingToken, false, 1),
        rateOracle,
        mustInvert,
        buffer,
        haircut,
        liquidationDiscount
    );

    assert false;
}