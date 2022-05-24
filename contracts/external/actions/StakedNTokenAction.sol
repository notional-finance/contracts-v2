// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import {INTokenProxy} from "../../../interfaces/notional/INTokenProxy.sol";
import {IStakedNTokenAction} from "../../../../interfaces/notional/IStakedNTokenAction.sol";
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
        return nTokenStakerLib.balanceOf(currencyId, account, block.timestamp);
    }

    /// @notice Returns the present value of the entire staked nTokens supply in underlying external
    function stakedNTokenPresentValueUnderlyingExternal(uint16 currencyId) external override view returns (uint256) {
        StakedNTokenSupply memory stakedSupply = StakedNTokenSupplyLib.getStakedNTokenSupply(currencyId);
        (
            uint256 valueInAssetCash,
            /* */,
            AssetRateParameters memory assetRate
        ) = stakedSupply.getSNTokenPresentValueView(currencyId, block.timestamp);

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
        int256 nTokensMinted = nTokenMintAction.nTokenMint(currencyId, assetTokensReceivedInternal);
        // When we mint and stake nTokens directly, we do not go via the balance handler so we have to update the
        // total supply on the nToken directly. This also updates accumulatedNOTEPerNToken and sets it in storage.
        nTokenSupply.changeNTokenSupply(nTokenHandler.nTokenAddress(currencyId), nTokensMinted, block.timestamp);

        snTokensMinted = nTokenStakerLib.stakeNToken(receiver, currencyId, nTokensMinted.toUint(), block.timestamp);
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
        uint256 nTokenClaim = nTokenStakerLib.unstakeNToken(owner, currencyId, shares, block.timestamp);
        int256 assetCash = nTokenRedeemAction.nTokenRedeemViaBatch(currencyId, nTokenClaim.toInt());

        // Redeem Tokens to Sender
        Token memory assetToken = TokenHandler.getAssetToken(currencyId);
        assetToken.redeem(currencyId, receiver, assetToken.convertToExternal(assetCash).toUint());
    }

    /**** Called from Batch Action  ****/

    function stakeNTokenViaBatch(address account, uint16 currencyId, uint256 nTokensToStake) external override returns (uint256 snTokensMinted) {
        require(msg.sender == address(this));
        snTokensMinted = nTokenStakerLib.stakeNToken(account, currencyId, nTokensToStake, block.timestamp);
        
        // This emits a Transfer(address(0), account, snTokensMinted) event for tracking ERC20 balances
        INTokenProxy(StakedNTokenSupplyLib.getStakedNTokenAddress(currencyId)).emitMint(account, snTokensMinted);
    }

    function unstakeNTokenViaBatch(address account, uint16 currencyId, uint256 unstakeAmount) external override returns (uint256 nTokenClaim) {
        require(msg.sender == address(this));
        nTokenClaim = nTokenStakerLib.unstakeNToken(account, currencyId, unstakeAmount, block.timestamp);

        // This emits a Transfer(account, address(0), unstakeAmount) event for tracking ERC20 balances
        INTokenProxy(StakedNTokenSupplyLib.getStakedNTokenAddress(currencyId)).emitBurn(msg.sender, unstakeAmount);
    }

    /**** Direct call to Notional, must be authenticated via msg.sender  ****/

    /// @notice Sets an unstake signal for the account, called from msg.sender
    function signalUnstakeNToken(uint16 currencyId, uint256 amount) external {
        nTokenStakerLib.setUnstakeSignal(msg.sender, currencyId, amount, block.timestamp);
    }

    function claimStakedNTokenIncentives(uint16[] calldata currencyId) external {
        // TODO add a method for this
    }

}