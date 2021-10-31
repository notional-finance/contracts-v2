// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

interface FlashLiquidatorProxy {
    function transferOwnership(address newOwner) external;

    function flashLoan(
        address flashLender,
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}
