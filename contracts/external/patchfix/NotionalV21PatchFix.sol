// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./BasePatchFixRouter.sol";
import "./SettlementRateFix.sol";
import "./MigrateIncentivesFix.sol";

contract NotionalV21PatchFix is BasePatchFixRouter, SettlementRateFix, MigrateIncentivesFix {

    constructor(address finalRouter, NotionalProxy proxy) BasePatchFixRouter(finalRouter, proxy) {}

    function _patchFix() internal override {
        _patchFixIncentives();
        _patchFixSettlementRates();
    }
}