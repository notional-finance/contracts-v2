// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.11;

import {ERC20} from "@openzeppelin-4.6/contracts/token/ERC20/ERC20.sol";

contract MockCToken is ERC20 {
    uint private _answer;
    uint private _supplyRate;
    uint8 internal _decimals;
    address public underlying;
    function decimals() public view override returns (uint8) { return _decimals; }
    event AccrueInterest(uint cashPrior, uint interestAccumulated, uint borrowIndex, uint totalBorrows);

    constructor(uint8 decimals_) ERC20("cMock", "cMock") {
        _decimals = _decimals;
        _mint(msg.sender, type(uint80).max);
    }

    function setUnderlying(address underlying_) external {
        underlying = underlying_;
    }

    function setAnswer(uint a) external {
        _answer = a;
    }

    function setSupplyRate(uint a) external {
        _supplyRate = a;
    }

    function exchangeRateCurrent() external returns (uint) {
        // This is here to test if we've called the right function
        emit AccrueInterest(0, 0, 0, 0);
        return _answer;
    }

    function exchangeRateStored() external view returns (uint) {
        return _answer;
    }

    function supplyRatePerBlock() external view returns (uint) {
        return _supplyRate;
    }

    function accrualBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function interestRateModel() external view returns (address) {
        return address(0);
    }
}


