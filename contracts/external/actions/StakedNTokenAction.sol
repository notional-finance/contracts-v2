// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import {IStakedNTokenAction} from "../../../../interfaces/notional/IStakedNTokenAction.sol";
import {nTokenStaker, StakedNTokenSupply, nTokenStaked} from "../../internal/nToken/nTokenStaked.sol";

contract StakedNTokenAction is IStakedNTokenAction {

    modifier onlyStakedNTokenProxy(uint16 currencyId) {
        require(msg.sender == nTokenStaked.stakedNTokenAddress(currencyId));
        _;
    }

    function stakedNTokenTotalSupply(uint16 currencyId) external override view returns (
        uint256
    ) {
        return nTokenStaked.getStakedNTokenSupply(currencyId).totalSupply;
    }

    function stakedNTokenBalanceOf(uint16 currencyId, address account) external override view returns (
        uint256
    ) {
        return nTokenStaked.getNTokenStaker(account, currencyId).stakedNTokenBalance;
    }

    function stakedNTokenTransfer(
        uint16 currencyId,
        address from,
        address to,
        uint256 amount
    ) external override onlyStakedNTokenProxy(currencyId) returns (bool) {
        nTokenStaked.transferStakedNToken(from, to, currencyId, amount, block.timestamp);
    }

    function stakedNTokenRedeemAllowed(uint16 currencyId, address account) 
        external override view returns (uint256) {

    }


    function stakedNTokenRedeemViaProxy(uint16 currencyId, uint256 shares, address receiver, address owner)
        external override onlyStakedNTokenProxy(currencyId)
        returns (uint256) {

        }

    function stakedNTokenMintViaProxy(uint16 currencyId, uint256 assets, address receiver)
        external override onlyStakedNTokenProxy(currencyId)
        returns (uint256) {

        }

    function stakedNTokenPresentValueUnderlyingExternal(uint16 currencyId)
        external override view
        returns (uint256) {

        }

    function stakedNTokenSignalUnstake(uint16 currencyId, address account, uint256 amount)
        external override onlyStakedNTokenProxy(currencyId) {

    }
}