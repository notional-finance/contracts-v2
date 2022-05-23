// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import {INTokenProxy} from "../../../interfaces/notional/INTokenProxy.sol";
import {IStakedNTokenAction} from "../../../../interfaces/notional/IStakedNTokenAction.sol";
import {UnstakeNTokenMethod} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

import {nTokenStaker, nTokenStakerLib} from "../../internal/nToken/staking/nTokenStaker.sol";
import {StakedNTokenSupply, StakedNTokenSupplyLib} from "../../internal/nToken/staking/StakedNTokenSupply.sol";
import {nTokenSupply} from "../../internal/nToken/nTokenSupply.sol";
import {nTokenHandler} from "../../internal/nToken/nTokenHandler.sol";
import {AssetRate, AssetRateParameters} from "../../internal/markets/AssetRate.sol";
import {BalanceHandler, BalanceState} from "../../internal/balances/BalanceHandler.sol";
import {Token, TokenHandler} from "../../internal/balances/TokenHandler.sol";
import {AccountContext, AccountContextHandler} from "../../internal/AccountContextHandler.sol";

import {nTokenRedeemAction} from "./nTokenRedeemAction.sol";
import {nTokenMintAction} from "./nTokenMintAction.sol";
import {FreeCollateralExternal} from "../FreeCollateralExternal.sol";
import {SettleAssetsExternal} from "../SettleAssetsExternal.sol";

contract StakedNTokenAction is IStakedNTokenAction {
    using StakedNTokenSupplyLib for StakedNTokenSupply;
    using BalanceHandler for BalanceState;
    using AccountContextHandler for AccountContext;
    using TokenHandler for Token;
    using AssetRate for AssetRateParameters;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    /// @notice Authenticates calls to the proxy
    modifier onlyStakedNTokenProxy(uint16 currencyId) {
        require(msg.sender == StakedNTokenSupplyLib.getStakedNTokenAddress(currencyId));
        _;
    }

    /// @notice Returns the total supply
    function stakedNTokenTotalSupply(uint16 currencyId)
        external override view returns (uint256) {
        return StakedNTokenSupplyLib.getStakedNTokenSupply(currencyId).totalSupply;
    }

    /// @notice Returns the balance of an account
    function stakedNTokenBalanceOf(uint16 currencyId, address account)
        external override view returns (uint256) {
        return nTokenStakerLib.getStaker(account, currencyId).snTokenBalance;
    }

    /// @notice Returns the present value of the entire staked nTokens supply in underlying external
    function stakedNTokenPresentValueUnderlyingExternal(uint16 currencyId) external override view returns (uint256) {
        StakedNTokenSupply memory stakedSupply = StakedNTokenSupplyLib.getStakedNTokenSupply(currencyId);
        (
            uint256 valueInAssetCash,
            /* */,
            AssetRateParameters memory assetRate
        ) = stakedSupply.getSNTokenPresentValue(currencyId, block.timestamp);

        return assetRate.convertToUnderlying(valueInAssetCash.toInt())
            .mul(assetRate.underlyingDecimals)
            .div(Constants.INTERNAL_TOKEN_PRECISION)
            .toUint();
    }

    /// @notice If the account can redeem staked nTokens, returns the max amount they can redeem
    function stakedNTokenRedeemAllowed(uint16 currencyId, address account) 
        external override view returns (uint256) {
        (/* */, uint256 maxUnstake, /* */, bool canUnstake) = nTokenStakerLib.canAccountUnstake(
            account, currencyId, block.timestamp
        );
        return canUnstake ? maxUnstake : 0;
    }


    /**** ERC20 Proxy Stateful Methods, must be authenticated via modifier  ****/

    /**
     * @notice Transfers staked nTokens between accounts.
     * @param from account to transfer from
     * @param to account to transfer to
     * @param currencyId currency id of the nToken
     * @param amount amount of staked nTokens to transfer
     */
    function stakedNTokenTransfer(
        uint16 currencyId,
        address from,
        address to,
        uint256 amount
    ) external override onlyStakedNTokenProxy(currencyId) returns (bool) {
        StakedNTokenSupply memory stakedSupply = StakedNTokenSupplyLib.getStakedNTokenSupply(currencyId);

        // Update the incentive accumulators then the incentives on each staker, no nToken supply change
        uint256 accumulatedNOTE = stakedSupply.updateAccumulatedNOTE(currencyId, block.timestamp, 0);
        nTokenStakerLib.updateStakerBalance(from, currencyId, amount.toInt().neg(), accumulatedNOTE);
        nTokenStakerLib.updateStakerBalance(to, currencyId, amount.toInt(), accumulatedNOTE);
    }

    /// @notice Mints staked nTokens from some amount of underlying tokens transferred to Notional from
    /// the proxy. The receiver will get the staked nTokens.
    function stakedNTokenMintViaProxy(uint16 currencyId, uint256 assets, address receiver)
        external payable override onlyStakedNTokenProxy(currencyId)
        returns (uint256 snTokensMinted) {

        // The proxy will have transferred to Notional exactly assets amount in underlying
        Token memory assetToken = TokenHandler.getAssetToken(currencyId);
        int256 assetTokensReceivedInternal = assetToken.convertToInternal(assetToken.mint(currencyId, assets));
        snTokensMinted = _mintAndStakeNToken(currencyId, receiver, assetTokensReceivedInternal);
    }

    /// @notice Sets an unstake signal for the account, called from the proxy
    function stakedNTokenSignalUnstake(uint16 currencyId, address account, uint256 amount)
        external override onlyStakedNTokenProxy(currencyId) {
        nTokenStakerLib.setUnstakeSignal(account, currencyId, amount, block.timestamp);
    }

    /// @notice Redeems "shares" amount of staked nTokens from the owner and then redeems them to underlying.
    /// Transfers the underlying tokens to the receiver account.
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

    /**** Direct call to Notional, must be authenticated via msg.sender  ****/

    // TODO: see if we can move this into batch action
    function stakeNToken(
        uint16 currencyId,
        uint256 nTokensToStake,
        uint256 depositAmountExternal,
        bool useUnderlying
    ) external returns (uint256 snTokensMinted) {
        AccountContext memory stakerContext = AccountContextHandler.getAccountContext(msg.sender);
        // When removing nTokens from an account context, it is potentially used as collateral. We check
        // if the account has to settle, remove the nTokens via transfer (such that we do not change the
        // total supply of nTokens) and then check free collateral if required.
        if (stakerContext.mustSettleAssets()) {
            stakerContext = SettleAssetsExternal.settleAccount(msg.sender, stakerContext);
        }

        BalanceState memory stakerBalance;
        stakerBalance.loadBalanceState(msg.sender, currencyId, stakerContext);
        stakerBalance.netNTokenTransfer = nTokensToStake.toInt().neg();
        stakerBalance.finalize(msg.sender, stakerContext, false);
        stakerContext.setAccountContext(msg.sender);
        // TODO: need to emit a Transfer event on the nToken here

        // nTokens are used as collateral so we have to check the free collateral when we transfer.
        if (stakerContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(msg.sender);
        }

        snTokensMinted = nTokenStakerLib.stakeNToken(msg.sender, currencyId, nTokensToStake, block.timestamp);
        
        // This emits a Transfer(address(0), account, snTokensMinted) event for tracking ERC20 balances
        INTokenProxy(StakedNTokenSupplyLib.getStakedNTokenAddress(currencyId)).emitMint(msg.sender, snTokensMinted);
    }

    /// @notice Sets an unstake signal for the account, called from msg.sender
    function signalUnstakeNToken(uint16 currencyId, uint256 amount) external {
        nTokenStakerLib.setUnstakeSignal(msg.sender, currencyId, amount, block.timestamp);
    }

    function unstakeNToken(
        uint16 currencyId,
        uint256 unstakeAmount,
        address receiver,
        UnstakeNTokenMethod unstakeMethod
    ) external {
        _unstakeNToken(currencyId, msg.sender, receiver, unstakeAmount, unstakeMethod);

        // This emits a Transfer(account, address(0), unstakeAmount) event for tracking ERC20 balances
        INTokenProxy(StakedNTokenSupplyLib.getStakedNTokenAddress(currencyId)).emitBurn(msg.sender, unstakeAmount);
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
        int256 nTokensMinted = nTokenMintAction.nTokenMint(currencyId, assetTokensReceivedInternal);
        // When we mint and stake nTokens directly, we do not go via the balance handler so we have to update the
        // total supply on the nToken directly. This also updates accumulatedNOTEPerNToken and sets it in storage.
        nTokenSupply.changeNTokenSupply(nTokenHandler.nTokenAddress(currencyId), nTokensMinted, block.timestamp);

        snTokensMinted = nTokenStakerLib.stakeNToken(account, currencyId, nTokensMinted.toUint(), block.timestamp);
    }
}