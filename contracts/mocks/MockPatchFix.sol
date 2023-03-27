// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../external/patchfix/BasePatchFixRouter.sol";
import "../external/patchfix/SettlementRateFix.sol";

contract MockPatchFix is BasePatchFixRouter, SettlementRateFix {
    constructor(
        address currentRouter,
        address finalRouter,
        NotionalProxy proxy
    ) BasePatchFixRouter(currentRouter, finalRouter, proxy) {}

    function _patchFix() internal override {
        _patchFixSettlementRates();
    }
}
