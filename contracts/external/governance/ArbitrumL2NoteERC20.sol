// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;

import "./NoteERC20.sol";
import "interfaces/arbitrum/IArbToken.sol";

contract ArbitrumL2NoteERC20 is NoteERC20, IArbToken {
    address public immutable l2Gateway;
    address public immutable override l1Address;

    /// @notice Tracks the total supply minted in arbitrum
    uint96 public arbitrumTotalSupply;

    event BridgeMint(address account, uint256 amount);
    event BridgeBurn(address account, uint256 amount);

    modifier onlyGateway() {
        require(msg.sender == l2Gateway, "ONLY_l2GATEWAY");
        _;
    }

    constructor(address _l2Gateway, address _l1Address) NoteERC20() {
        l2Gateway = _l2Gateway;
        l1Address = _l1Address;
    }

    function initialize(
        address[] calldata initialAccounts,
        uint96[] calldata initialGrantAmount,
        address owner_
    ) public override initializer {
        owner = owner_;
    }

    function bridgeMint(address account, uint256 _amount) external override onlyGateway {
        uint96 amount = _safe96(_amount, "Note::bridgeMint:amount overflow");

        balances[account] = _add96(
            balances[account],
            amount,
            "Note::bridgeMint: transfer amount overflows"
        );

        arbitrumTotalSupply = _add96(arbitrumTotalSupply, amount, "Total supply overflow");

        // Mint votes to the account being delegated to
        _moveDelegates(address(0), delegates[account], amount);

        emit Transfer(address(0), account, amount);
        emit BridgeMint(account, amount);
    }

    function bridgeBurn(address account, uint256 _amount) external override onlyGateway {
        uint96 amount = _safe96(_amount, "Note::bridgeMint:amount overflow");

        balances[account] = _sub96(
            balances[account],
            amount,
            "Note::bridgeBurn: transfer amount overflows"
        );

        arbitrumTotalSupply = _sub96(arbitrumTotalSupply, amount, "Total supply overflow");

        // Burn votes on the account being delegated to
        _moveDelegates(delegates[account], address(0), amount);

        emit Transfer(account, address(0), amount);
        emit BridgeBurn(account, amount);
    }
}