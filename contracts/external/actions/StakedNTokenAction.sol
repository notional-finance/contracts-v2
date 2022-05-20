// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import {IStakedNTokenAction} from "../../../../interfaces/notional/IStakedNTokenAction.sol";
import {UnstakeNTokenMethod} from "../../global/Types.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {nTokenStaker, StakedNTokenSupply, nTokenStaked} from "../../internal/nToken/nTokenStaked.sol";
import {BalanceHandler, BalanceState} from "../../internal/balances/BalanceHandler.sol";
import {Token, TokenHandler} from "../../internal/balances/TokenHandler.sol";
import {AccountContext, AccountContextHandler} from "../../internal/AccountContextHandler.sol";

import {nTokenRedeemAction} from "./nTokenRedeemAction.sol";
import {nTokenMintAction} from "./nTokenMintAction.sol";
import {FreeCollateralExternal} from "../FreeCollateralExternal.sol";
import {SettleAssetsExternal} from "../SettleAssetsExternal.sol";

contract StakedNTokenAction is IStakedNTokenAction {
    using BalanceHandler for BalanceState;
    using AccountContextHandler for AccountContext;
    using TokenHandler for Token;
    using SafeInt256 for int256;

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

    function stakedNTokenRedeemAllowed(uint16 currencyId, address account) 
        external override view returns (uint256) {
        // TODO

    }

    function stakedNTokenPresentValueUnderlyingExternal(uint16 currencyId)
        external override view
        returns (uint256) {
        // TODO

    }

    function stakedNTokenPresentValue(uint16 currencyId)
        external view
        returns (uint256) {
        // TODO

    }

    // These are called via the ERC20 proxy

    function stakedNTokenTransfer(
        uint16 currencyId,
        address from,
        address to,
        uint256 amount
    ) external override onlyStakedNTokenProxy(currencyId) returns (bool) {
        nTokenStaked.transferStakedNToken(from, to, currencyId, amount, block.timestamp);
    }

    function stakedNTokenMintViaProxy(uint16 currencyId, uint256 assets, address receiver)
        external override onlyStakedNTokenProxy(currencyId) returns (uint256 snTokensMinted) {

        // The proxy will have transferred to Notional exactly assets amount in underlying
        Token memory assetToken = TokenHandler.getAssetToken(currencyId);
        int256 assetTokensReceivedInternal = assetToken.convertToInternal(
            assetToken.mint(currencyId, assets)
        );

        snTokensMinted = _mintAndStakeNToken(currencyId, receiver, assetTokensReceivedInternal);
    }

    function stakedNTokenSignalUnstake(uint16 currencyId, address account, uint256 amount)
        external override onlyStakedNTokenProxy(currencyId) {

    }

    function stakedNTokenRedeemViaProxy(uint16 currencyId, uint256 shares, address receiver, address owner)
        external override onlyStakedNTokenProxy(currencyId)
        returns (uint256 assetsTransferred) {
        assetsTransferred = _unstakeNToken(
            currencyId,
            owner,
            receiver,
            shares,
            UnstakeNTokenMethod.TransferToAccountUnderlying
        );
    }

    // NOTE: these methods use msg.sender

    function stakeNToken(uint16 currencyId, uint256 nTokensToStake) external {
        // TODO transfer from cash balance

        // need to do FC check
    }

    function mintAndStakeNToken(
        uint16 currencyId,
        uint256 depositAmountExternal,
        bool useUnderlying
    ) external {
        // TODO: Transfer tokens in....

        // _mintAndStakeNToken(currencyId, msg.sender, assetTokensReceivedInternal);
    }

    function signalUnstakeNToken(uint16 currencyId, uint256 amount) external {
        // TODO
    }


    function unstakeNToken(
        uint16 currencyId,
        uint256 unstakeAmount,
        address receiver,
        UnstakeNTokenMethod unstakeMethod
    ) external {
        _unstakeNToken(currencyId, msg.sender, receiver, unstakeAmount, unstakeMethod);
    }

    function _unstakeNToken(
        uint16 currencyId,
        address staker,
        address receiver,
        uint256 unstakeAmount,
        UnstakeNTokenMethod unstakeMethod
    ) internal returns (uint256 assetsTransferred) {
        // TODO
    }

    function _mintAndStakeNToken(
        uint16 currencyId,
        address account,
        int256 assetTokensReceivedInternal
    ) internal returns (uint256 snTokensMinted) {
        uint256 nTokensMinted = nTokenMintAction.nTokenMint(currencyId, assetTokensReceivedInternal).toUint();
        snTokensMinted = nTokenStaked.stakeNToken(account, currencyId, nTokensMinted, block.timestamp);
    }
}