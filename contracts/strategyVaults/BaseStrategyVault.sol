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

    uint16 internal immutable BORROW_CURRENCY_ID;
    bool internal immutable USE_UNDERLYING_TOKEN;
    TokenType internal immutable ASSET_TOKEN_TYPE;
    ERC20 public immutable ASSET_TOKEN;
    ERC20 public immutable UNDERLYING_TOKEN;
    NotionalProxy public immutable NOTIONAL;
    ILendingPool public immutable AAVE_LENDING_POOL;

    // Return code for cTokens that represents no error
    uint256 internal constant COMPOUND_RETURN_CODE_NO_ERROR = 0;
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
        uint16 borrowCurrencyId_,
        bool setApproval,
        bool useUnderlyingToken
    ) {
        name = name_;
        NOTIONAL = NotionalProxy(notional_);
        BORROW_CURRENCY_ID = borrowCurrencyId_;
        USE_UNDERLYING_TOKEN = useUnderlyingToken;
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
        if (setApproval && underlyingToken.tokenAddress != address(0)) {
            // If the parent wants to, set up token approvals for minting
            if (assetToken.tokenType == TokenType.cToken) {
                ERC20(underlyingToken.tokenAddress).safeApprove(assetToken.tokenAddress, type(uint256).max);
            } else if (assetToken.tokenType == TokenType.aToken) {
                ERC20(underlyingToken.tokenAddress).safeApprove(lendingPool, type(uint256).max);
            }
        }
    }

    // External methods are authenticated to be just Notional
    function depositFromNotional(
        address account,
        uint256 deposit,
        uint256 maturity,
        bytes calldata data
    ) external onlyNotional returns (uint256 strategyTokensMinted) {
        uint256 tokenAmount = USE_UNDERLYING_TOKEN ? _redeemAssetTokens(deposit) : deposit;
        return _depositFromNotional(account, tokenAmount, maturity, data);
    }

    function redeemFromNotional(
        address account,
        uint256 strategyTokens,
        uint256 maturity,
        bytes calldata data
    ) external onlyNotional {
        uint256 tokensFromRedeem = _redeemFromNotional(account, strategyTokens, maturity, data);
        uint256 assetTokensToTransfer = USE_UNDERLYING_TOKEN ? _mintAssetTokens(tokensFromRedeem) : tokensFromRedeem;

        ASSET_TOKEN.transfer(address(NOTIONAL), assetTokensToTransfer);
    }

    function _redeemAssetTokens(uint256 assetTokens) internal returns (uint256 underlyingTokens) {
        // In this case, there is no minting or redeeming required
        if (ASSET_TOKEN_TYPE == TokenType.NonMintable) return assetTokens;

        uint256 balanceBefore;
        uint256 balanceAfter;
        if (ASSET_TOKEN_TYPE == TokenType.cETH) {
            // Special handling for ETH balance selector

            balanceBefore = address(this).balance;
            uint256 success = CErc20Interface(address(ASSET_TOKEN)).redeem(assetTokens);
            require(success == COMPOUND_RETURN_CODE_NO_ERROR, "Redeem");
            balanceAfter = address(this).balance;
        } else {
            balanceBefore = UNDERLYING_TOKEN.balanceOf(address(this));
            if (ASSET_TOKEN_TYPE == TokenType.cToken) {
                uint256 success = CErc20Interface(address(ASSET_TOKEN)).redeem(assetTokens);
                require(success == COMPOUND_RETURN_CODE_NO_ERROR, "Redeem");
            } else if (ASSET_TOKEN_TYPE == TokenType.aToken) {
                AAVE_LENDING_POOL.withdraw(address(UNDERLYING_TOKEN), assetTokens, address(this));
            }
            balanceAfter = UNDERLYING_TOKEN.balanceOf(address(this));
        }

        return balanceAfter - balanceBefore;
    }

    function _mintAssetTokens(uint256 underlyingTokens) internal returns (uint256 assetTokens) {
        // In this case, there is no minting or redeeming required
        if (ASSET_TOKEN_TYPE == TokenType.NonMintable) return underlyingTokens;

        uint256 balanceBefore = ASSET_TOKEN.balanceOf(address(this));
        if (ASSET_TOKEN_TYPE == TokenType.cToken) {
            uint256 success = CErc20Interface(address(ASSET_TOKEN)).mint(underlyingTokens);
            require(success == COMPOUND_RETURN_CODE_NO_ERROR, "Mint");
        } else if (ASSET_TOKEN_TYPE == TokenType.aToken) {
            AAVE_LENDING_POOL.deposit(address(UNDERLYING_TOKEN), underlyingTokens, address(this), 0);
        } else if (ASSET_TOKEN_TYPE == TokenType.cETH) {
            // Reverts on error
            CEtherInterface(address(ASSET_TOKEN)).mint{value: underlyingTokens}();
        }
        uint256 balanceAfter = ASSET_TOKEN.balanceOf(address(this));

        return balanceAfter - balanceBefore;
    }
}