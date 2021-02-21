// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

// Bring these open zeppelin contracts into the build for brownie
import "@openzeppelin/contracts/access/TimelockController.sol";
import "@openzeppelin/contracts/proxy/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/TransparentUpgradeableProxy.sol";

contract nTimelockController is TimelockController {
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors) { }
}

contract nProxyAdmin is ProxyAdmin { }

contract nTransparentUpgradeableProxy is TransparentUpgradeableProxy {
    constructor(address _logic, address admin_, bytes memory _data)
        TransparentUpgradeableProxy(_logic, admin_, _data) { }
}
