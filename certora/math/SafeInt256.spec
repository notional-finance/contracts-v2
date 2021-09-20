methods {
    mul(int256 a, int256 b) returns (int256) envfree
    div(int256 a, int256 b) returns (int256) envfree
    sub(int256 x, int256 y) returns (int256 z) envfree
    add(int256 x, int256 y) returns (int256 z) envfree
    neg(int256 x) returns (int256) envfree
    abs(int256 x) returns (int256) envfree
    subNoNeg(int256 x, int256 y) returns (int256) envfree
    divInRatePrecision(int256 x, int256 y) returns (int256) envfree
    mulInRatePrecision(int256 x, int256 y) returns (int256) envfree
}

rule mulDoesNotOverflow(int256 x, int256 y) {
    int256 result = mul(x, y);
    assert y == 0 || x == 0 => result == 0;
    assert x == 1 => result == x;
    assert y == 1 => result == y;
    assert y != 0 => div(x, y) == result;
}

