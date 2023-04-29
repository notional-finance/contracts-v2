// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import {UUPSUpgradeable} from "./utils/UUPSUpgradeable.sol";

// Empty proxy for deploying to an address first and then allows the deployer to upgrade
// to the implementation later.
contract EmptyProxy is UUPSUpgradeable {
    address public immutable owner;

    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function _authorizeUpgrade(address /* */) internal view override {
        require(owner == msg.sender, "Unauthorized upgrade");
    }

    constructor(address _owner) {
        owner = _owner;
    }
}