methods {
    setBit(bytes32 bitmap, uint256 index, bool setOn) returns (bytes32) envfree;
    isBitSet(bytes32 bitmap, uint256 index) returns (bool) envfree;
    totalBitsSet(bytes32 bitmap) returns (uint256) envfree;
    naiveCountBits(bytes32 bitmap) returns (uint256) envfree;
    getMSB(uint256 x) returns (uint256 msb) envfree;
    getNextBitNum(bytes32 bitmap) returns (uint256 bitNum) envfree;
    bytesToUint(bytes32 bitmap) returns (uint256 x) envfree;
    uintToBytes(uint256 bitmap) returns (bytes32 x) envfree;
    packTo56Bits(uint256 value) returns (bytes32 x) envfree;
    unpackFrom56Bits(uint256 value) returns (uint256 x) envfree;
}

rule setBitTurnsBitOn(bytes32 bitmap, uint256 index, bool setOn) {
    require 1 <= index && index <= 256;
    bytes32 newBitmap = setBit(bitmap, index, setOn);
    assert isBitSet(newBitmap, index) == setOn;
    // TODO: this causes a type error
    // assert (bytesToUint(newBitmap) & (1 << (index - 1))) != 0;
}

rule findsMostSignificantBit(uint256 bitmap) {
    require bitmap != 0;

    uint256 msb = getMSB(bitmap);
    // Turning off the MSB should result in a smaller value if there
    // are not any more significant bits set.
    uint256 msbValue = 1 << msb;
    uint256 invMSBValue = (2 ^ 256 - 1) - msbValue;
    assert (bitmap & invMSBValue) < msbValue;

    // Next bit num is the 1-indexed, big-endian version of MSB
    uint256 nextBitNum = getNextBitNum(uintToBytes(bitmap));
    assert isBitSet(uintToBytes(bitmap), nextBitNum);
}

rule floatingPoint56Under48Bits(uint256 value) {
    require value <= (2 ^ 48) - 1;
    assert unpackFrom56Bits(bytesToUint(packTo56Bits(value))) == value;
}

// TODO: is it possible to prove this?
// rule totalBitsSet(bytes32 bitmap) {
//     assert totalBitsSet(bitmap) == naiveCountBits(bitmap);
// }

// TODO: get an error on a call trace exception
// [ForkJoinPool-151-worker-27] ERROR log.Logger - report.CallTraceException: Failed to construct the call trace on the rule floatingPoint56Over48Bits: invalid state of the call stack ([floatingPoint56Over48Bits(value=0xa5f7e00808080000000000000000), packedUint = bytesToUint(packTo56Bits(value)), MathHarness.bytesToUint(*), MathHarness.packTo56Bits(a5f7e00808080000000000000000), (internal) packTo56Bits(uint256)])
//         at report.CallTraceExceptionKt.callTraceConstructionFailure(CallTraceException.kt:17)
// Verification report:
// https://vaas-stg.certora.com/output/42394/cc617658a5722f08f12a?anonymousKey=773257aef776230538dbeda791e55607d09f572b
// Run script: certora/scripts/runBitmap floatingPoint56Over48Bits
rule floatingPoint56Over48Bits(uint256 value) {
    require value > (2 ^ 48) - 1;
    uint256 packedUint = bytesToUint(packTo56Bits(value));
    uint256 fpValue = unpackFrom56Bits(packedUint);
    uint256 shiftedBits = packedUint & 0xFF;
    uint256 shiftedAmount = 1 << shiftedBits;

    assert value >= fpValue;
    // Max precision loss due to shifting
    assert value - fpValue <= shiftedAmount;
}