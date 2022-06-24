// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.11;
pragma abicoder v2;

import {Token, TokenType} from "../global/Types.sol";
import {IStrategyVault} from "../../../interfaces/notional/IStrategyVault.sol";
import {NotionalProxy} from "../../../interfaces/notional/NotionalProxy.sol";
import {IVaultController} from "../../../interfaces/notional/IVaultController.sol";
import {ERC20} from "@openzeppelin-4.6/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin-4.6/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILendingPool} from "../../interfaces/aave/ILendingPool.sol";
import {CErc20Interface} from "../../../../interfaces/compound/CErc20Interface.sol";
import {CEtherInterface} from "../../../../interfaces/compound/CEtherInterface.sol";

abstract contract BaseStrategyVault is IStrategyVault {
    using SafeERC20 for ERC20;

    /** These view methods need to be implemented by the vault */
    function convertStrategyToUnderlying(address account, uint256 strategyTokens, uint256 maturity) public view virtual returns (int256 underlyingValue);
    
    // Vaults need to implement these two methods
    function _depositFromNotional(
        address account,
        uint256 deposit,
        uint256 maturity,
        bytes calldata data
    ) internal virtual returns (uint256 strategyTokensMinted);

    function _redeemFromNotional(
        address account,
        uint256 strategyTokens,
        uint256 maturity,
        bytes calldata data
    ) internal virtual returns (uint256 tokensFromRedeem);

    // This can be overridden if the vault borrows in a secondary currency, but reverts by default.
    function _repaySecondaryBorrowCallback(
        uint256 assetCashRequired, bytes calldata data
    ) internal virtual returns (bytes memory returnData) {
        revert();
    }

    uint16 internal immutable BORROW_CURRENCY_ID;
    ERC20 internal immutable UNDERLYING_TOKEN;
    bool internal immutable UNDERLYING_IS_ETH;
    NotionalProxy public immutable NOTIONAL;

    uint8 constant internal INTERNAL_TOKEN_DECIMALS = 8;
    string public override name;
    function decimals() public view returns (uint8) { return INTERNAL_TOKEN_DECIMALS; }

    modifier onlyNotional() {
        require(msg.sender == address(NOTIONAL));
        _;
    }

    constructor(
        string memory name_,
        address notional_,
        uint16 borrowCurrencyId_
    ) {
        name = name_;
        NOTIONAL = NotionalProxy(notional_);
        BORROW_CURRENCY_ID = borrowCurrencyId_;

        (
            Token memory assetToken,
            Token memory underlyingToken,
            /* ETHRate memory ethRate */,
            /* AssetRateParameters memory assetRate */
        ) = NotionalProxy(notional_).getCurrencyAndRates(borrowCurrencyId_);

        address underlyingAddress = assetToken.tokenType == TokenType.NonMintable ?
            assetToken.tokenAddress : underlyingToken.tokenAddress;
        UNDERLYING_TOKEN = ERC20(underlyingAddress);
        UNDERLYING_IS_ETH = underlyingToken.tokenType == TokenType.Ether;
    }

    // External methods are authenticated to be just Notional
    function depositFromNotional(
        address account,
        uint256 deposit,
        uint256 maturity,
        bytes calldata data
    ) external payable onlyNotional returns (uint256 strategyTokensMinted) {
        return _depositFromNotional(account, deposit, maturity, data);
    }

    function redeemFromNotional(
        address account,
        address receiver,
        uint256 strategyTokens,
        uint256 maturity,
        uint256 underlyingToRepayDebt,
        bytes calldata data
    ) external onlyNotional {
        uint256 tokensFromRedeem = _redeemFromNotional(account, strategyTokens, maturity, data);

        uint256 transferToNotional;
        uint256 transferToAccount;
        if (account == address(this) || tokensFromRedeem <= underlyingToRepayDebt) {
            // It may be the case that insufficient tokens were redeemed to repay the debt. If this
            // happens the Notional will attempt to recover the shortfall from the account directly.
            // This can happen if an account wants to reduce their leverage by paying off debt but
            // does not want to sell strategy tokens to do so.
            // The other situation would be that the vault is calling redemption to deleverage or
            // settle. In that case all tokens go back to Notional.
            transferToNotional = tokensFromRedeem;
        } else {
            transferToNotional = underlyingToRepayDebt;
            unchecked { transferToAccount = tokensFromRedeem - underlyingToRepayDebt; }
        }

        if (UNDERLYING_IS_ETH) {
            if (transferToAccount > 0) payable(receiver).transfer(transferToAccount);
            if (transferToNotional > 0) payable(address(NOTIONAL)).transfer(transferToNotional);
        } else {
            if (transferToAccount > 0) UNDERLYING_TOKEN.safeTransfer(receiver, transferToAccount);
            if (transferToNotional > 0) UNDERLYING_TOKEN.safeTransfer(address(NOTIONAL), transferToNotional);
        }
    }

    function repaySecondaryBorrowCallback(
        uint256 assetCashRequired, bytes calldata data
    ) external onlyNotional returns (bytes memory returnData) {
        return _repaySecondaryBorrowCallback(assetCashRequired, data);
    }

    receive() external payable {
        // Allow ETH transfers to succeed
    }
}