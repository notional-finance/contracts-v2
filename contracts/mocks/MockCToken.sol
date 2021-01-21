// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;

contract MockCToken {
    uint private _answer;
    uint8 public decimals;
    string public symbol = "cMock";

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    function setAnswer(uint a) external {
        _answer = a;
    }

    function exchangeRateCurrent() external returns (uint) {
        return _answer;
    }
}


