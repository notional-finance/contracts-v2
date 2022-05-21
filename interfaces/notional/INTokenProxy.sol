// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

/// @notice Interface is used to emit Transfer events from the nToken ERC20 proxy so
/// that off chain tracking tools like Etherscan can properly see token creation
interface INTokenProxy {
    function emitMint(address account, uint256 amount) external;
    function emitBurn(address account, uint256 amount) external;
}