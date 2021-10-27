// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../../global/LibStorage.sol";
import "../../global/Types.sol";
import "./BasePatchFixRouter.sol";

contract SettlementRateFix is BasePatchFixRouter {
    uint256 internal constant ETH = 1;
    uint256 internal constant DAI = 2;
    uint256 internal constant USDC = 3;
    uint256 internal constant WBTC = 4;
    uint256 internal constant MAR_29_2022 = 1648512000;
    uint256 internal constant SEP_24_2022 = 1664064000;

    event SetSettlementRate(uint256 indexed currencyId, uint256 indexed maturity, uint128 rate);

    constructor(address finalRouter, NotionalProxy proxy) BasePatchFixRouter(finalRouter, proxy) {}

    function _patchFix() internal override {
        // Delete these settlement rates that have been set previously
        _deleteSettlementRate(ETH, MAR_29_2022);
        _deleteSettlementRate(DAI, MAR_29_2022);
        _deleteSettlementRate(USDC, MAR_29_2022);
        _deleteSettlementRate(WBTC, MAR_29_2022);
        _deleteSettlementRate(DAI, SEP_24_2022);
        _deleteSettlementRate(USDC, SEP_24_2022);
    }

    function _deleteSettlementRate(uint256 currencyId, uint256 maturity) private {
        mapping(uint256 => mapping(uint256 => SettlementRateStorage)) storage store = LibStorage.getSettlementRateStorage();
        delete store[currencyId][maturity];
        emit SetSettlementRate(currencyId, maturity, 0);
    }

}