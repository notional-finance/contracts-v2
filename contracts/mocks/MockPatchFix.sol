// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../external/patchfix/BasePatchFixRouter.sol";
import "../external/patchfix/SettlementRateFix.sol";

contract MockPatchFix is BasePatchFixRouter, SettlementRateFix {

    constructor(address finalRouter, NotionalProxy proxy) BasePatchFixRouter(finalRouter, proxy) {}

    function _patchFix() internal override {
        _patchFixSettlementRates();
    }
}