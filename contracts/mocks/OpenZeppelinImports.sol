// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

// Bring these open zeppelin contracts into the build for brownie
import "@openzeppelin/contracts/proxy/ProxyAdmin.sol";

contract nProxyAdmin is ProxyAdmin { }