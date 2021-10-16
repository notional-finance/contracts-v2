// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.9;
pragma abicoder v2;

// Bring these open zeppelin contracts into the build for brownie
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract nProxyAdmin is ProxyAdmin { }
contract nTransparentUpgradeableProxy is TransparentUpgradeableProxy {
    constructor(
        address _logic,
        address admin_,
        bytes memory _data
    ) TransparentUpgradeableProxy(_logic, admin_, _data) {}

    receive() external payable override {}
}