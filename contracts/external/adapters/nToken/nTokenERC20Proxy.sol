// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {INTokenAction} from "../../../../interfaces/notional/INTokenAction.sol";
import {BaseNTokenProxy} from "./BaseNTokenProxy.sol";

contract nTokenERC20Proxy is BaseNTokenProxy {

    constructor(address notional_) BaseNTokenProxy(notional_) { }

    function initialize(
        uint16 currencyId_,
        string memory underlyingName_,
        string memory underlyingSymbol_
    ) external override {
        // This method is marked as an initializer and will prevent this from being called twice
        _initialize(currencyId_, underlyingName_, underlyingSymbol_, false);
    }

    /// @notice Total number of tokens in circulation
    function totalSupply() public view override returns (uint256) {
        // Total supply is looked up via the token address
        return INTokenAction(Notional).nTokenTotalSupply(address(this));
    }

    /// @notice Get the number of tokens held by the `account`
    /// @param account The address of the account to get the balance of
    /// @return The number of tokens held
    function balanceOf(address account) public view override returns (uint256) {
        return INTokenAction(Notional).nTokenBalanceOf(currencyId, account);
    }

    /// @notice Get the number of tokens `spender` is approved to spend on behalf of `account`
    /// @param account The address of the account holding the funds
    /// @param spender The address of the account spending the funds
    /// @return The number of tokens approved
    function allowance(address account, address spender) external view override returns (uint256) {
        return INTokenAction(Notional).nTokenTransferAllowance(currencyId, account, spender);
    }

    /// @notice Approve `spender` to transfer up to `amount` from `src`
    /// @dev This will overwrite the approval amount for `spender`
    ///  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
    ///  emit:Approval
    /// @param spender The address of the account which may transfer tokens
    /// @param amount The number of tokens that are approved (2^256-1 means infinite)
    /// @return Whether or not the approval succeeded
    function approve(address spender, uint256 amount) external override returns (bool) {
        bool success = INTokenAction(Notional).nTokenTransferApprove(currencyId, msg.sender, spender, amount);
        // Emit approvals here so that they come from the correct contract address
        if (success) emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Transfer `amount` tokens from `msg.sender` to `to`
    /// @dev emit:Transfer
    /// @param to The address of the destination account
    /// @param amount The number of tokens to transfer
    /// @return Whether or not the transfer succeeded
    function transfer(address to, uint256 amount) external override returns (bool) {
        bool success = INTokenAction(Notional).nTokenTransfer(currencyId, msg.sender, to, amount);
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
        bool success =
            INTokenAction(Notional).nTokenTransferFrom(currencyId, msg.sender, from, to, amount);

        // Emit transfer events here so they come from the correct contract
        if (success) emit Transfer(from, to, amount);
        return success;
    }

    /// @notice Returns the present value of the nToken's assets denominated in asset tokens
    function getPresentValueAssetDenominated() external view returns (int256) {
        return INTokenAction(Notional).nTokenPresentValueAssetDenominated(currencyId);
    }

    /// @notice Returns the present value of the nToken's assets denominated in underlying
    function getPresentValueUnderlyingDenominated() external view returns (int256) {
        return INTokenAction(Notional).nTokenPresentValueUnderlyingDenominated(currencyId);
    }

    function _getUnderlyingPVExternal() internal view override returns (uint256 pvUnderlyingExternal) {
        return INTokenAction(Notional).nTokenPresentValueUnderlyingExternal(currencyId);
    }

    function maxWithdraw(address owner) external override view returns (uint256 maxAssets) {
        return convertToShares(balanceOf(owner));
    }

    function maxRedeem(address owner) external view override returns (uint256 maxShares) {
        return balanceOf(owner);
    }

    function _redeem(uint256 shares, address receiver, address owner) internal override returns (uint256 assets) {
        return INTokenAction(Notional).nTokenRedeemViaProxy(currencyId, shares, receiver, owner);
    }

    function _mint(uint256 assets, address receiver) internal override returns (uint256 tokensMinted) {
        return INTokenAction(Notional).nTokenMintViaProxy(currencyId, assets, receiver);
    }
}
