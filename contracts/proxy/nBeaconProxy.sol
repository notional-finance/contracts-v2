// SPDX-License-Identifier: MIT

pragma solidity =0.7.6;

import "./beacon/BeaconProxy.sol";

contract nBeaconProxy is BeaconProxy {
    constructor(address beacon, bytes memory data) payable BeaconProxy(beacon, data) {}

    receive() external payable override {
        // Allow ETH transfers to succeed
    }

    function getImplementation() external view returns (address) {
        return _implementation();
    }

    function getBeacon() external view returns (address) {
        return _beacon();
    }
}
