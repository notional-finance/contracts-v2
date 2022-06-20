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
    function convertStrategyToUnderlying(uint256 strategyTokens, uint256 maturity) public view virtual returns (uint256 underlyingValue);
    
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
    TokenType internal immutable ASSET_TOKEN_TYPE;
    ERC20 public immutable ASSET_TOKEN;
    ERC20 public immutable UNDERLYING_TOKEN;
    NotionalProxy public immutable NOTIONAL;
    ILendingPool public immutable AAVE_LENDING_POOL;

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
        address lendingPool = NotionalProxy(notional_).getLendingPool(); 
        AAVE_LENDING_POOL = ILendingPool(lendingPool);

        (
            Token memory assetToken,
            Token memory underlyingToken,
            /* ETHRate memory ethRate */,
            /* AssetRateParameters memory assetRate */
        ) = NotionalProxy(notional_).getCurrencyAndRates(borrowCurrencyId_);

        ASSET_TOKEN = ERC20(assetToken.tokenAddress);
        ASSET_TOKEN_TYPE = assetToken.tokenType;
        UNDERLYING_TOKEN = ERC20(underlyingToken.tokenAddress);
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
        uint256 strategyTokens,
        uint256 maturity,
        bytes calldata data
    ) external onlyNotional {
        uint256 tokensFromRedeem = _redeemFromNotional(account, strategyTokens, maturity, data);

        // // TODO: handle ETH
        // // TODO: do not revert on underflow
        // UNDERLYING_TOKEN.transfer(account, tokensFromRedeem - underlyingTokensRequiredForRepayment);
        // UNDERLYING_TOKEN.transfer(address(NOTIONAL), underlyingTokensRequiredForRepayment);
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