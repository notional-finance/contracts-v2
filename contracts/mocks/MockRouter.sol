// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../proxy/utils/UUPSUpgradeable.sol";

contract MockRouter is UUPSUpgradeable {
    address public owner;

    function transferOwnership(address newOwner, bool direct) external {
        owner = newOwner;
    }

    function _authorizeUpgrade(address newImplementation) internal override {}
}
