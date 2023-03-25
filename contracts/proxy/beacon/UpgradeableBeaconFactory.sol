// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.3.2 (proxy/beacon/UpgradeableBeacon.sol)

pragma solidity =0.7.6;

import "@openzeppelin/contracts/utils/Create2.sol";
import "./UpgradeableBeacon.sol";

contract UpgradeableBeaconFactory {
    event BeaconDeployed(address beacon);
    
    function deployBeacon(
        address owner,
        address implementation,
        bytes32 salt
    ) external returns (address beacon) {
        beacon = Create2.deploy(
            0, // never transfer eth
            salt,
            abi.encodePacked(type(UpgradeableBeacon).creationCode, abi.encode(implementation))
        );

        UpgradeableBeacon(beacon).transferOwnership(owner);

        emit BeaconDeployed(beacon);
    }
}