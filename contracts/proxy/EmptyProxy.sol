// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

// Empty proxy for deploying to an address first and then allows the deployer to upgrade
// to the implementation later.
contract EmptyProxy {
    address internal immutable deployer;

    constructor()  {
        deployer = msg.sender;
    }
}