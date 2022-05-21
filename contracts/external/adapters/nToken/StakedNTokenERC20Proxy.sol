// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import {IStakedNTokenAction} from "../../../../interfaces/notional/IStakedNTokenAction.sol";
import {BaseNTokenProxy} from "./BaseNTokenProxy.sol";

contract StakedNTokenProxy is BaseNTokenProxy {
    mapping(address => mapping(address => uint256)) private _allowance;

    constructor(address notional_, address weth_) BaseNTokenProxy(notional_, weth_) { }

    function initialize(
        uint16 currencyId_,
        string memory underlyingName_,
        string memory underlyingSymbol_
    ) external override {
        // This method is marked as an initializer and will prevent this from being called twice
        _initialize(currencyId_, underlyingName_, underlyingSymbol_, true);
    }

    /// @notice Total number of tokens in circulation
    function totalSupply() public view override returns (uint256) {
        // Total supply is looked up via the token address
        return IStakedNTokenAction(Notional).stakedNTokenTotalSupply(currencyId);
    }

    /// @notice Get the number of tokens held by the `account`
    /// @param account The address of the account to get the balance of
    /// @return The number of tokens held
    function balanceOf(address account) public view override returns (uint256) {
        return IStakedNTokenAction(Notional).stakedNTokenBalanceOf(currencyId, account);
    }

    /// @notice Get the number of tokens `spender` is approved to spend on behalf of `account`
    /// @param account The address of the account holding the funds
    /// @param spender The address of the account spending the funds
    /// @return The number of tokens approved
    function allowance(address account, address spender) external view override returns (uint256) {
        return _allowance[account][spender];
    }

    /// @notice Approve `spender` to transfer up to `amount` from `src`
    /// @dev This will overwrite the approval amount for `spender`
    ///  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
    ///  emit:Approval
    /// @param spender The address of the account which may transfer tokens
    /// @param amount The number of tokens that are approved (2^256-1 means infinite)
    /// @return Whether or not the approval succeeded
    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Transfer `amount` tokens from `msg.sender` to `to`
    /// @dev emit:Transfer
    /// @param to The address of the destination account
    /// @param amount The number of tokens to transfer
    /// @return Whether or not the transfer succeeded
    function transfer(address to, uint256 amount) external override returns (bool) {
        bool success = IStakedNTokenAction(Notional).stakedNTokenTransfer(currencyId, msg.sender, to, amount);
        // Emit transfer events here so they come from the correct contract
        if (success) emit Transfer(msg.sender, to, amount);
        return success;
    }

    /// @notice Transfer `amount` tokens from `from` to `to`
    /// @dev emit:Transfer emit:Approval
    /// @param from The address of the source account
    /// @param to The address of the destination account
    /// @param amount The number of tokens to transfer
    /// @return Whether or not the transfer succeeded
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        bool success =
            IStakedNTokenAction(Notional).stakedNTokenTransfer(currencyId, from, to, amount);

        // Emit transfer events here so they come from the correct contract
        if (success) emit Transfer(from, to, amount);
        return success;
    }

    /// @notice Returns the value of the total supply of staked nTokens in external precision
    function _getUnderlyingPVExternal() internal view override returns (uint256 pvUnderlyingExternal) {
        return IStakedNTokenAction(Notional).stakedNTokenPresentValueUnderlyingExternal(currencyId);
    }

    /// @notice Suffers from estimation issues related to nToken redemption. maxAssets is an overestimation
    /// of the amount the owner can withdraw.
    function maxWithdraw(address owner) external override view returns (uint256 maxAssets) {
        return convertToShares(maxRedeem(owner));
    }

    /// @notice Maximum redemption amount will return a positive number during the unstake window if the 
    /// owner has signalled that they wil unstake, otherwise it will always be zero.
    function maxRedeem(address owner) public view override returns (uint256 maxShares) {
        return IStakedNTokenAction(Notional).stakedNTokenRedeemAllowed(currencyId, owner);
    }

    /// @notice Allows msg.sender to signal that they will unstake some amount of nTokens. Will only succeed
    /// during the unstake signalling window.
    function signalUnstake(uint256 amount) external {
        IStakedNTokenAction(Notional).stakedNTokenSignalUnstake(currencyId, msg.sender, amount);
    }

    function _redeem(uint256 shares, address receiver, address owner) internal override returns (uint256 assets) {
        if (receiver != owner) _spendAllowance(owner, msg.sender, shares);
        return IStakedNTokenAction(Notional).stakedNTokenRedeemViaProxy(currencyId, shares, receiver, owner);
    }

    function _mint(uint256 assets, uint256 msgValue, address receiver) internal override returns (uint256 tokensMinted) {
        return IStakedNTokenAction(Notional).stakedNTokenMintViaProxy{value: msgValue}(currencyId, assets, receiver);
    }

    function _spendAllowance(address account, address spender, uint256 amount) internal {
        uint256 allowance_ = _allowance[account][spender];
        require(amount <= allowance_, "Insufficient Allowance");
        _allowance[account][spender] = allowance_ - amount;
    }
}
