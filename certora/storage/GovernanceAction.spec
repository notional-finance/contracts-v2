methods {
    nTokenAddress(uint16 currencyId) returns (address) envfree;
    getNTokenAccount(address tokenAddress) returns (
        uint256 currencyId,
        uint256 totalSupply,
        uint256 incentiveAnnualEmissionRate,
        uint256 lastInitializedTime,
        uint8 arrayLen,
        bytes5 nTokenParameters,
        uint256 integralTotalSupply,
        uint256 lastSupplyChangeTime
    ) envfree;
    getNTokenParameters(address tokenAddress) returns (
        uint8 residualPurchaseIncentive10BPS,
        uint8 pvHaircutPercentage,
        uint8 residualPurchaseTimeBufferHours,
        uint8 cashWithholdingBuffer10BPS,
        uint8 liquidationHaircutPercentage,
        uint8 arrayLen,
        uint256 currencyId,
        uint256 incentiveAnnualEmissionRate,
        uint256 lastInitializedTime
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
    getMaxCurrencyId() returns (uint16) envfree;
    getToken(uint16 currencyId, bool isUnderlying)
        returns (
            address tokenAddress,
            bool hasTransferFee,
            int256 decimals,
            uint8 tokenType
        ) envfree;
    addIsEqual(uint256 totalSupply, int256 netChange, uint256 totalSupplyAfter) returns (bool) envfree;

    approve(address, uint256) => DISPATCHER(true);
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
    uint256 _currencyId;
    uint256 _lastInitializedTime;
    uint8 _arrayLen;
    bytes5 _nTokenParameters;
    _currencyId, _, _, _lastInitializedTime, _arrayLen, _nTokenParameters, _, _ = getNTokenAccount(tokenAddress);

    updateIncentiveEmissionRate(e, currencyId, newEmissionRate);
    uint256 incentiveEmissionRate;
    uint256 currencyId_;
    uint256 lastInitializedTime_;
    uint8 arrayLen_;
    bytes5 nTokenParameters_;
    currencyId_, _, incentiveEmissionRate, lastInitializedTime_, arrayLen_, nTokenParameters_, _, _ = getNTokenAccount(tokenAddress);
    assert incentiveEmissionRate == newEmissionRate;
    assert _currencyId == currencyId_;
    assert _lastInitializedTime == lastInitializedTime_;
    assert _nTokenParameters == nTokenParameters_;
    assert _arrayLen == arrayLen_;
}

// PASSES
rule updateArrayLengthAndTimeSetsProperly(
    uint16 currencyId,
    uint8 arrayLength,
    uint256 lastInitializedTime,
    address tokenAddress 
) {
    env e;
    require nTokenAddress(currencyId) == tokenAddress;
    uint8 _p1;
    uint8 _p2;
    uint8 _p3;
    uint8 _p4;
    uint8 _p5;
    uint256 _currencyId;
    uint256 _incentiveEmissionRate;
    _p1, _p2, _p3, _p4, _p5, _, _currencyId, _incentiveEmissionRate, _ = getNTokenParameters(tokenAddress);

    setArrayLengthAndInitializedTime(e, tokenAddress, arrayLength, lastInitializedTime);
    uint8 p1_;
    uint8 p2_;
    uint8 p3_;
    uint8 p4_;
    uint8 p5_;
    uint8 arrayLength_;
    uint256 lastInitializedTime_;
    uint256 currencyId_;
    uint256 incentiveEmissionRate_;

    p1_, p2_, p3_, p4_, p5_, arrayLength_, currencyId_, incentiveEmissionRate_, lastInitializedTime_ = getNTokenParameters(tokenAddress);

    assert _p1 == p1_;
    assert _p2 == p2_;
    assert _p3 == p3_;
    assert _p4 == p4_;
    assert _p5 == p5_;

    assert arrayLength == arrayLength_;
    assert _currencyId == currencyId_;
    assert _incentiveEmissionRate == incentiveEmissionRate_;
    assert lastInitializedTime == lastInitializedTime_;
}


// PASSES
rule updateNTokenSupplySetsProperly(
    uint16 currencyId,
    int256 netChange,
    address tokenAddress 
) {
    env e;
    require nTokenAddress(currencyId) == tokenAddress;
    uint256 _totalSupply;
    uint256 _integralTotalSupply;
    uint256 _lastSupplyChangeTime;

    _, _totalSupply, _, _, _, _, _integralTotalSupply, _lastSupplyChangeTime = getNTokenAccount(tokenAddress);
    require _lastSupplyChangeTime < e.block.timestamp;
    // It cannot be that there is an integral total supply value if last supply change time is zero.
    require _lastSupplyChangeTime == 0 => _integralTotalSupply == 0;

    uint256 calculatedIntegralTotalSupply = changeNTokenSupply(e, tokenAddress, netChange, e.block.timestamp);
    uint256 totalSupply_;
    uint256 integralTotalSupply_;
    uint256 lastSupplyChangeTime_;
    _, totalSupply_, _, _, _, _, integralTotalSupply_, lastSupplyChangeTime_ = getNTokenAccount(tokenAddress);

    assert netChange != 0 => addIsEqual(_totalSupply, netChange, totalSupply_);
    assert netChange != 0 => lastSupplyChangeTime_ == e.block.timestamp;
    assert netChange != 0 => integralTotalSupply_ == calculatedIntegralTotalSupply;

    // If net change is zero then nothing will change in storage
    assert netChange == 0 => _totalSupply == totalSupply_;
    assert netChange == 0 => _lastSupplyChangeTime == lastSupplyChangeTime_;
    assert netChange == 0 => _integralTotalSupply == integralTotalSupply_;
}

// PASSES
rule updateNTokenIntegralSupplyCalculatesProperly(
    uint16 currencyId,
    int256 netChange,
    address tokenAddress 
) {
    env e;
    require nTokenAddress(currencyId) == tokenAddress;
    uint256 _totalSupply;
    uint256 _integralTotalSupply;
    uint256 _lastSupplyChangeTime;

    _, _totalSupply, _, _, _, _, _integralTotalSupply, _lastSupplyChangeTime = getNTokenAccount(tokenAddress);
    require _lastSupplyChangeTime < e.block.timestamp;
    // It cannot be that there is an integral total supply value if last supply change time is zero.
    require _lastSupplyChangeTime == 0 => _integralTotalSupply == 0;

    uint256 calculatedIntegralTotalSupply = changeNTokenSupply(e, tokenAddress, netChange, e.block.timestamp);

    assert _lastSupplyChangeTime == 0 ? 
        // The integral total supply is zero when initialized
        calculatedIntegralTotalSupply == 0 :
        // In any other case it will increase
        calculatedIntegralTotalSupply == (
            _integralTotalSupply + _totalSupply * (e.block.timestamp - _lastSupplyChangeTime)
        );
}

// PASSES
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
    uint8 _arrayLen;
    uint256 _currencyId;
    uint256 _incentiveEmissionRate;
    uint256 _lastInitializedTime;
    _, _, _, _, _, _arrayLen, _currencyId, _incentiveEmissionRate, _lastInitializedTime = getNTokenParameters(tokenAddress);

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
    uint8 arrayLen_;
    uint256 currencyId_;
    uint256 incentiveEmissionRate_;
    uint256 lastInitializedTime_;

    p1, p2, p3, p4, p5, arrayLen_, currencyId_, incentiveEmissionRate_, lastInitializedTime_ = getNTokenParameters(tokenAddress);
    assert p1 == residualPurchaseIncentive10BPS;
    assert p2 == pvHaircutPercentage;
    assert p3 == residualPurchaseTimeBufferHours;
    assert p4 == cashWithholdingBuffer10BPS;
    assert p5 == liquidationHaircutPercentage;

    assert _arrayLen == arrayLen_;
    assert _currencyId == currencyId_;
    assert _incentiveEmissionRate == incentiveEmissionRate_;
    assert _lastInitializedTime == lastInitializedTime_;
}

// TODO: TIMEOUT
// https://vaas-stg.certora.com/output/42394/0ce55b2dd5e7919ae790/?anonymousKey=1e8823b19fffc4f56d375fcb505400cd31253930
rule cashGroupSetsProperly() {
    env e;
    // Allow the method below to call itself to use calldata.
    require getOwner() == currentContract;

    bool didVerify;
    calldataarg args;
    // try callargs here
    didVerify = setCashGroupStorageAndVerify(e, args);

    assert didVerify;
}

// FAILS VERIFICATION: Don't understand the results here:
// https://vaas-stg.certora.com/output/42394/b346a20fccf3161bd2e4/?anonymousKey=14f6dc1b5fe2c24e852ffadc82182619a4438eb2
rule updateETHRateGetsProperly(
    uint16 currencyId,
    address rateOracle,
    bool mustInvert,
    uint8 buffer,
    uint8 haircut,
    uint8 liquidationDiscount
) {
    env e;
    updateETHRate(
        e,
        currencyId,
        rateOracle,
        mustInvert,
        buffer,
        haircut,
        liquidationDiscount
    );

    int256 _rateDecimals;
    int256 _rate;
    uint8 _buffer;
    uint8 _haircut;
    uint8 _liquidationDiscount;

    _rateDecimals, _rate, _buffer, _haircut, _liquidationDiscount = getETHRate(currencyId);
    // Special case for ETH
    assert currencyId == 1 ? _rateDecimals == 10 ^ 18 : _rateDecimals == 10;
    assert currencyId == 1 => _rate == 10 ^ 18;
    // assert currencyId != 1 && mustInvert => _rate == 100;
    // assert currencyId != 1 && !mustInvert => _rate == 1;

    assert buffer == _buffer;
    assert haircut == _haircut;
    assert liquidationDiscount == _liquidationDiscount;
}

// TODO: don't understand the results here:
// https://vaas-stg.certora.com/output/42394/ef51ca3fc3207b7b1475/?anonymousKey=40154ad311dd2e6cded9eb80b8a49302d01811f6
rule updateAssetRateSetsProperly(
    uint16 currencyId,
    address rateOracle
) {
    env e;
    updateAssetRate(e, currencyId, rateOracle);
    address _rateOracle;
    int256 rate;
    int256 underlyingDecimalPlaces;

    // Appears that underlying decimal places is not returned properly
    _rateOracle, rate, underlyingDecimalPlaces = getAssetRate(e, currencyId);

    assert _rateOracle == rateOracle;
    assert rateOracle == 0 => underlyingDecimalPlaces == 0 && rate == 10 ^ 10;
}

// ERRORS:
// [pool-1-thread-13] ERROR smtlibutils.satresult - Got more than one answer to a check-sat query: [(:reason-unknown ""), sat].
// [pool-1-thread-13] ERROR smtlibutils.satresult - Got more than one answer to a check-sat query: [(:reason-unknown ""), sat].
// [pool-1-thread-13] ERROR smtlibutils.satresult - Got more than one answer to a check-sat query: [(:reason-unknown ""), sat].
// [pool-1-thread-13] ERROR smtlibutils.satresult - Got more than one answer to a check-sat query: [(:reason-unknown ""), unknown].
// [pool-1-thread-13] ERROR smtlibutils.satresult - Got more than one answer to a check-sat query: [(:reason-unknown "timeout"), sat].
// [pool-1-thread-13] ERROR smtlibutils.satresult - Got more than one answer to a check-sat query: [(:reason-unknown ""), sat].
// [pool-1-thread-13] ERROR smtlibutils.satresult - Got more than one answer to a check-sat query: [(:reason-unknown ""), sat].
// Results don't make sense, now getting a sanity check failed
// https://vaas-stg.certora.com/output/42394/906efcd49e8d7ebab1cf?anonymousKey=aa0fbfb87b1294221ee1fb27e6dcc2b6dfd758de
// Storage value looks correct but does not return the correct value for decimals.
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
    uint16 maxCurrencyId = getMaxCurrencyId();
    require getOwner() == currentContract;
    require maxCurrencyId >= 1;
    require assetToken != 0;
    require underlyingToken != 0;

    listCurrencyHarness(
        e,
        assetToken, false, 1,
        underlyingToken, false, 0,
        rateOracle,
        mustInvert,
        buffer,
        haircut,
        liquidationDiscount
    );

    address assetToken_;
    bool assetTokenHasFee_;
    int256 assetTokenDecimals_;
    assetToken_, assetTokenHasFee_, assetTokenDecimals_, _ = getToken(maxCurrencyId + 1, false);

    assert assetToken_ == assetToken;
    assert assetTokenHasFee_ == false;
    assert assetTokenDecimals_ == 10^8;

    address underlyingToken_;
    bool underlyingTokenHasFee_;
    int256 underlyingTokenDecimals_;
    underlyingToken_, underlyingTokenHasFee_, underlyingTokenDecimals_, _ = getToken(maxCurrencyId + 1, true);

    assert underlyingToken_ == underlyingToken;
    assert underlyingTokenHasFee_ == false;
    assert underlyingTokenDecimals_ == 10^18;
}