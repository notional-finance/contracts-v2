// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.7.6;

import {WETH9} from "../../interfaces/WETH9.sol";
import {IUpgradeableBeacon} from "../proxy/beacon/IBeacon.sol";

/// @title Hardcoded deployed contracts are listed here. These are hardcoded to reduce
/// gas costs for immutable addresses. They must be updated per environment that Notional
/// is deployed to.
library Deployments {
    address internal constant NOTE_TOKEN_ADDRESS = 0xCFEAead4947f0705A14ec42aC3D44129E1Ef3eD5;
    WETH9 internal constant WETH = WETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    enum BeaconType {
        NTOKEN,
        PCASH,
        WRAPPED_FCASH
    }

    // NOTE: these are temporary Beacon addresses
    IUpgradeableBeacon internal constant NTOKEN_BEACON = IUpgradeableBeacon(0xC73f1f7d9287129b6707Dad6121016aF4e22A63D);
    IUpgradeableBeacon internal constant PCASH_BEACON = IUpgradeableBeacon(0x70d6ca4b41A2faddD1B6e49a7b75B3Aa17B5B172);
    IUpgradeableBeacon internal constant PDEBT_BEACON = IUpgradeableBeacon(0xB166810A73969c6562e8C738B8f24a734086aD1d);
    IUpgradeableBeacon internal constant WRAPPED_FCASH_BEACON = IUpgradeableBeacon(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // TODO: this will be set to the timestamp of the final settlement time in notional v2,
    // no assets can be settled prior to this date once the notional v3 upgrade is enabled.
    uint256 internal constant NOTIONAL_V2_FINAL_SETTLEMENT = 0;
}
