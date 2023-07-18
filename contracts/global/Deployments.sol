// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.7.6;

import {WETH9} from "../../interfaces/WETH9.sol";
import {IUpgradeableBeacon} from "../proxy/beacon/IBeacon.sol";
import {AggregatorV2V3Interface} from "../../interfaces/chainlink/AggregatorV2V3Interface.sol";

/// @title Hardcoded deployed contracts are listed here. These are hardcoded to reduce
/// gas costs for immutable addresses. They must be updated per environment that Notional
/// is deployed to.
library Deployments {
    uint256 internal constant MAINNET = 1;
    uint256 internal constant ARBITRUM_ONE = 42161;
    uint256 internal constant LOCAL = 1337;

    // MAINNET: 0xCFEAead4947f0705A14ec42aC3D44129E1Ef3eD5
    // address internal constant NOTE_TOKEN_ADDRESS = 0xCFEAead4947f0705A14ec42aC3D44129E1Ef3eD5;
    // ARBITRUM: 0x019bE259BC299F3F653688c7655C87F998Bc7bC1
    address internal constant NOTE_TOKEN_ADDRESS = 0x019bE259BC299F3F653688c7655C87F998Bc7bC1;

    // MAINNET: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    // WETH9 internal constant WETH = WETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    // ARBITRUM: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
    WETH9 internal constant WETH = WETH9(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    // OPTIMISM: 0x4200000000000000000000000000000000000006

    // Chainlink L2 Sequencer Uptime: https://docs.chain.link/data-feeds/l2-sequencer-feeds/
    // MAINNET: NOT SET
    // AggregatorV2V3Interface internal constant SEQUENCER_UPTIME_ORACLE = AggregatorV2V3Interface(address(0));
    // ARBITRUM: 0xFdB631F5EE196F0ed6FAa767959853A9F217697D
    AggregatorV2V3Interface internal constant SEQUENCER_UPTIME_ORACLE = AggregatorV2V3Interface(0xFdB631F5EE196F0ed6FAa767959853A9F217697D);

    enum BeaconType {
        NTOKEN,
        PCASH,
        PDEBT,
        WRAPPED_FCASH
    }

    // NOTE: these are temporary Beacon addresses
    IUpgradeableBeacon internal constant NTOKEN_BEACON = IUpgradeableBeacon(0xc4FD259b816d081C8bdd22D6bbd3495DB1573DB7);
    IUpgradeableBeacon internal constant PCASH_BEACON = IUpgradeableBeacon(0x1F681977aF5392d9Ca5572FB394BC4D12939A6A9);
    IUpgradeableBeacon internal constant PDEBT_BEACON = IUpgradeableBeacon(0xDF08039c0af34E34660aC7c2705C0Da953247640);
    IUpgradeableBeacon internal constant WRAPPED_FCASH_BEACON = IUpgradeableBeacon(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // TODO: this will be set to the timestamp of the final settlement time in notional v2,
    // no assets can be settled prior to this date once the notional v3 upgrade is enabled.
    uint256 internal constant NOTIONAL_V2_FINAL_SETTLEMENT = 0;
}
