// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.11;
pragma abicoder v2;

import {Token} from "../global/Types.sol";
import {IStrategyVaultCustom} from "../../../interfaces/notional/IStrategyVault.sol";
import {NotionalProxy} from "../../../interfaces/notional/NotionalProxy.sol";
import {IVaultController} from "../../../interfaces/notional/IVaultController.sol";
import {ERC20} from "@openzeppelin-4.6/contracts/token/ERC20/ERC20.sol";

abstract contract BaseStrategyVault is ERC20, IStrategyVaultCustom {
    function deposit(
        uint256 deposit,
        address receiver,
        bytes calldata data
    ) internal virtual returns (uint256 strategyTokensMinted);

    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        bytes calldata data
    ) internal virtual returns (uint256 tokensReturned);

    function convertStrategyToUnderlying(uint256 strategyTokens) public view virtual returns (uint256 underlyingValue);
    function isInSettlement() external view virtual returns (bool);
    
    uint16 internal immutable BORROW_CURRENCY_ID;
    // IERC20 public immutable ASSET_TOKEN;
    // IERC20 public immutable UNDERLYING_TOKEN;
    uint256 constant internal INTERNAL_TOKEN_PRECISION = 1e8;
    uint8 constant internal INTERNAL_TOKEN_DECIMALS = 8;
    IVaultController public immutable NOTIONAL;
    uint256 immutable internal UNDERLYING_TOKEN_PRECISION;

    function decimals() public view override returns (uint8) { return INTERNAL_TOKEN_DECIMALS; }

    modifier onlyNotional() {
        require(msg.sender == address(NOTIONAL));
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address notional_,
        uint16 borrowCurrencyId_
    ) ERC20(name_, symbol_) {
        NOTIONAL = IVaultController(notional_);
        BORROW_CURRENCY_ID = borrowCurrencyId_;

        (
            /* Token memory assetToken */,
            Token memory underlyingToken,
            /* ETHRate memory ethRate */,
            /* AssetRateParameters memory assetRate */
        ) = NotionalProxy(notional_).getCurrencyAndRates(borrowCurrencyId_);

        require(underlyingToken.decimals > 0);
        UNDERLYING_TOKEN_PRECISION = uint256(underlyingToken.decimals);
    }

    // TODO: asset token mint / redeem methods
    //function canSettleMaturity(uint256 maturity) external view virtual returns (bool);
    
    /** 
     * @notice Vaults can optionally settle their matured pools back into either 100% strategy
     * tokens or 100% asset cash. Only Notional can call this method.
     */
    function settleMaturedPool(
        uint256 maturity,
        bool rebaseToAssetCash,
        bytes calldata vaultData
    ) external onlyNotional override {
        MaturityPool memory maturityPool = vaultMaturityPools[maturity];

        if (rebaseToAssetCash && maturityPool.totalStrategyTokens > 0) {
            uint256 assetCashWithdrawn = _redeemStrategyTokens(address(0), maturity, maturityPool.totalStrategyTokens, vaultData);
            maturityPool.totalAssetCash += _safeUint128(assetCashWithdrawn);
            maturityPool.totalStrategyTokens = 0;
        } else if (maturityPool.totalAssetCash > 0) {
            uint256 strategyTokensMinted = _mintStrategyTokens(address(0), maturity, maturityPool.totalAssetCash, vaultData);
            maturityPool.totalStrategyTokens += _safeUint128(strategyTokensMinted);
            maturityPool.totalAssetCash = 0;
        }

        vaultMaturityPools[maturity] = maturityPool;
    }

}