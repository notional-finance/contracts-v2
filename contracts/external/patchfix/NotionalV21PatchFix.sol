// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "./BasePatchFixRouter.sol";
import "./SettlementRateFix.sol";
import "./MigrateIncentivesFix.sol";

contract NotionalV21PatchFix is BasePatchFixRouter, SettlementRateFix, MigrateIncentivesFix {
    constructor(
        address currentRouter,
        address finalRouter,
        NotionalProxy proxy
    ) BasePatchFixRouter(currentRouter, finalRouter, proxy) {}

    function _patchFix() internal override {
        _patchFixIncentives();
        _patchFixSettlementRates();
    }
}
