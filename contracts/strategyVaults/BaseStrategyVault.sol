// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.11;
pragma abicoder v2;

import {Token, TokenType} from "../global/Types.sol";
import {IStrategyVaultCustom} from "../../../interfaces/notional/IStrategyVault.sol";
import {NotionalProxy} from "../../../interfaces/notional/NotionalProxy.sol";
import {IVaultController} from "../../../interfaces/notional/IVaultController.sol";
import {ERC20} from "@openzeppelin-4.6/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin-4.6/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract BaseStrategyVault is ERC20, IStrategyVaultCustom {
    using SafeERC20 for ERC20;

    /** These view methods need to be implemented by the vault */
    function canSettleMaturity(uint256 maturity) external view virtual returns (bool);
    function convertStrategyToUnderlying(uint256 strategyTokens) public view virtual returns (uint256 underlyingValue);
    function isInSettlement() external view virtual returns (bool);
    

    uint16 internal immutable BORROW_CURRENCY_ID;
    ERC20 public immutable ASSET_TOKEN;
    ERC20 public immutable UNDERLYING_TOKEN;
    IVaultController public immutable NOTIONAL;
    uint8 constant internal INTERNAL_TOKEN_DECIMALS = 8;
    function decimals() public view override returns (uint8) { return INTERNAL_TOKEN_DECIMALS; }

    modifier onlyNotional() {
        require(msg.sender == address(NOTIONAL));
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address notional_,
        uint16 borrowCurrencyId_,
        bool setApproval
    ) ERC20(name_, symbol_) {
        NOTIONAL = IVaultController(notional_);
        BORROW_CURRENCY_ID = borrowCurrencyId_;

        (
            Token memory assetToken,
            Token memory underlyingToken,
            /* ETHRate memory ethRate */,
            /* AssetRateParameters memory assetRate */
        ) = NotionalProxy(notional_).getCurrencyAndRates(borrowCurrencyId_);

        ASSET_TOKEN = ERC20(assetToken.tokenAddress);
        UNDERLYING_TOKEN = ERC20(underlyingToken.tokenAddress);
        if (setApproval && underlyingToken.tokenAddress != address(0)) {
            // If the parent wants to, set up token approvals for minting
            if (assetToken.tokenType == TokenType.cToken) {
                ERC20(underlyingToken.tokenAddress).safeApprove(assetToken.tokenAddress, type(uint256).max);
            } else if (assetToken.tokenType == TokenType.aToken) {
                address lendingPool = NotionalProxy(notional_).getLendingPool();
                ERC20(underlyingToken.tokenAddress).safeApprove(lendingPool, type(uint256).max);
            }
        }
    }

    // External methods are authenticated to be just Notional
    function depositFromNotional(uint256 deposit, bytes calldata data) external onlyNotional returns (uint256 strategyTokensMinted) {
        return _depositFromNotional(deposit, data);
    }

    function redeemFromNotional(uint256 strategyTokens, bytes calldata data) external onlyNotional {
        uint256 assetTokensToTransfer = _redeemFromNotional(strategyTokens, data);

        ASSET_TOKEN.transfer(address(NOTIONAL), assetTokensToTransfer);
    }

    // Vaults need to implement these two methods
    function _depositFromNotional(uint256 deposit, bytes calldata data) internal virtual returns (uint256 strategyTokensMinted);
    function _redeemFromNotional(uint256 strategyTokens, bytes calldata data) internal virtual returns (uint256 assetTokensToTransfer);
}