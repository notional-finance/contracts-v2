// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../../interfaces/notional/NotionalProxy.sol";
import "../../../interfaces/compound/CErc20Interface.sol";
import "../../../interfaces/compound/CEtherInterface.sol";
import "../../../interfaces/IWstETH.sol";
import "./LiquidatorStorageLayoutV1.sol";
import "../../internal/markets/DateTime.sol";
import {WETH9} from "../../../interfaces/WETH9.sol";
import {TokenHandler} from "../../internal/balances/TokenHandler.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

struct LiquidationAction {
    uint8 liquidationType;
    bool withdrawProfit;
    bool hasTransferFee;
    bytes payload;
}

struct LocalCurrencyLiquidation {
    address liquidateAccount;
    uint16 localCurrency;
    uint96 maxNTokenLiquidation;
}

struct CollateralCurrencyLiquidation {
    address liquidateAccount;
    uint16 localCurrency;
    address localCurrencyAddress;
    uint16 collateralCurrency;
    address collateralAddress;
    address collateralUnderlyingAddress;
    uint128 maxCollateralLiquidation;
    uint96 maxNTokenLiquidation;
    TradeData tradeData;
}

struct LocalfCashLiquidation {
    address liquidateAccount;
    uint16 localCurrency;
    uint256[] fCashMaturities;
    uint256[] maxfCashLiquidateAmounts;
}

struct CrossCurrencyfCashLiquidation {
    address liquidateAccount;
    uint16 localCurrency;
    address localCurrencyAddress;
    uint16 fCashCurrency;
    address fCashAddress;
    address fCashUnderlyingAddress;
    uint256[] fCashMaturities;
    uint256[] maxfCashLiquidateAmounts;
    TradeData tradeData;
}

struct TradeData {
    address dexAddress;
    bytes params;
}

enum LiquidationType {
    LocalCurrency,
    CollateralCurrency,
    LocalfCash,
    CrossCurrencyfCash
}

abstract contract BaseLiquidator is LiquidatorStorageLayoutV1 {
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    NotionalProxy public immutable NOTIONAL;
    WETH9 public immutable WETH;
    IWstETH public immutable wstETH;

    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    constructor(
        NotionalProxy notional_,
        address weth_,
        IWstETH wstETH_,
        address owner_
    ) {
        NOTIONAL = notional_;
        WETH = WETH9(weth_);
        wstETH = wstETH_;
        owner = owner_;
    }

    function checkAllowanceOrSet(address erc20, address spender) internal {
        if (IERC20(erc20).allowance(address(this), spender) < 2**128) {
            IERC20(erc20).approve(spender, type(uint256).max);
        }
    }

    function enableCurrencies(uint16[] calldata currencies) external onlyOwner {
        for (uint256 i; i < currencies.length; i++) {
            _enableCurrency(currencies[i]);
        }
    }

    function approveTokens(address[] calldata tokens, address spender) external onlyOwner {
        for (uint256 i; i < tokens.length; i++) {
            IERC20(tokens[i]).approve(spender, 0);
            IERC20(tokens[i]).approve(spender, type(uint256).max);
        }
    }

    function _enableCurrency(uint16 currencyId) internal virtual returns (address) {
        (
            /* Token memory assetToken */, 
            Token memory underlyingToken
        ) = NOTIONAL.getCurrency(currencyId);

        // Notional V3 needs to be able to pull underlying
        if (underlyingToken.tokenAddress != Constants.ETH_ADDRESS) {
            checkAllowanceOrSet(underlyingToken.tokenAddress, address(NOTIONAL));
        }

        return underlyingToken.tokenAddress;
    }

    function _liquidateLocal(LiquidationAction memory action, address[] memory assets) internal {
        LocalCurrencyLiquidation memory liquidation = abi.decode(
            action.payload,
            (LocalCurrencyLiquidation)
        );

        uint256 msgValue;
        if (liquidation.localCurrency == Constants.ETH_CURRENCY_ID) {
            (
                int256 localPrimeCashFromLiquidator, 
                int256 netNTokenTransfer
            ) = NOTIONAL.calculateLocalCurrencyLiquidation(
                liquidation.liquidateAccount, 
                liquidation.localCurrency, 
                liquidation.maxNTokenLiquidation
            );

            (
                /* Token memory assetToken */, 
                Token memory underlyingToken
            ) = NOTIONAL.getCurrency(liquidation.localCurrency);

            msgValue = TokenHandler.convertToExternal(underlyingToken, localPrimeCashFromLiquidator).toUint();
        }
        
        // prettier-ignore
        (
            /* int256 localAssetCashFromLiquidator */,
            int256 netNTokens
        ) = NOTIONAL.liquidateLocalCurrency(
            liquidation.liquidateAccount, 
            liquidation.localCurrency, 
            liquidation.maxNTokenLiquidation
        );

        // Will withdraw entire cash balance. Don't redeem local currency here because it has been flash
        // borrowed and we need to redeem the entire balance to underlying for the flash loan repayment.
        _redeemAndWithdraw(liquidation.localCurrency, uint96(netNTokens), false);
    }

    function _liquidateCollateral(LiquidationAction memory action, address[] memory assets)
        internal
    {
        CollateralCurrencyLiquidation memory liquidation = abi.decode(
            action.payload,
            (CollateralCurrencyLiquidation)
        );

        if (action.hasTransferFee) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            uint256 amount = IERC20(assets[0]).balanceOf(address(this));
            checkAllowanceOrSet(assets[0], address(NOTIONAL));
            NOTIONAL.depositUnderlyingToken(address(this), liquidation.localCurrency, amount);
        }

        // prettier-ignore
        (
            /* int256 localAssetCashFromLiquidator */,
            /* int256 collateralAssetCash */,
            int256 collateralNTokens
        ) = NOTIONAL.liquidateCollateralCurrency(
            liquidation.liquidateAccount,
            liquidation.localCurrency,
            liquidation.collateralCurrency,
            liquidation.maxCollateralLiquidation,
            liquidation.maxNTokenLiquidation,
            true, // Withdraw collateral
            false // Redeem to underlying (will happen later)
        ); 

        // Do not redeem stETH
        if (liquidation.collateralCurrency != 5) {
            // Redeem to underlying for collateral because it needs to be traded on the DEX
            _redeemAndWithdraw(liquidation.collateralCurrency, uint96(collateralNTokens), true);

            CErc20Interface(liquidation.collateralAddress).redeem(
                IERC20(liquidation.collateralAddress).balanceOf(address(this))
            );
        }

        if (liquidation.collateralCurrency == Constants.ETH_CURRENCY_ID) {
            // Wrap everything to WETH for trading
            _wrapToWETH();
        } else if (liquidation.collateralCurrency == 5) {
            // Unwrap to stETH for tradding
            _unwrapStakedETH();
        }

        // Will withdraw all cash balance, no need to redeem local currency, it will be
        // redeemed later
        if (action.hasTransferFee) _redeemAndWithdraw(liquidation.localCurrency, 0, false);
    }

    function _liquidateLocalfCash(LiquidationAction memory action, address[] memory assets)
        internal
    {
        LocalfCashLiquidation memory liquidation = abi.decode(
            action.payload,
            (LocalfCashLiquidation)
        );

        if (action.hasTransferFee) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            uint256 amount = IERC20(assets[0]).balanceOf(address(this));
            checkAllowanceOrSet(assets[0], address(NOTIONAL));
            NOTIONAL.depositUnderlyingToken(address(this), liquidation.localCurrency, amount);
        }

        // prettier-ignore
        (
            int256[] memory fCashNotionalTransfers,
            int256 localAssetCashFromLiquidator
        ) = NOTIONAL.liquidatefCashLocal(
            liquidation.liquidateAccount,
            liquidation.localCurrency,
            liquidation.fCashMaturities,
            liquidation.maxfCashLiquidateAmounts
        );

        // If localAssetCashFromLiquidator is negative (meaning the liquidator has received cash)
        // then when we will need to lend in order to net off the negative fCash. In this case we
        // will deposit the local asset cash back into notional.
        _sellfCashAssets(
            liquidation.localCurrency,
            liquidation.fCashMaturities,
            fCashNotionalTransfers,
            localAssetCashFromLiquidator < 0 ? uint256(localAssetCashFromLiquidator.abs()) : 0,
            false // No need to redeem to underlying here
        );

        // NOTE: no withdraw if _hasTransferFees, _sellfCashAssets with withdraw everything
    }

    function _liquidateCrossCurrencyfCash(LiquidationAction memory action, address[] memory assets)
        internal
    {
        CrossCurrencyfCashLiquidation memory liquidation = abi.decode(
            action.payload,
            (CrossCurrencyfCashLiquidation)
        );

        if (action.hasTransferFee) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            uint256 amount = IERC20(assets[0]).balanceOf(address(this));
            checkAllowanceOrSet(assets[0], address(NOTIONAL));
            NOTIONAL.depositUnderlyingToken(address(this), liquidation.localCurrency, amount);
        }

        // prettier-ignore
        (
            int256[] memory fCashNotionalTransfers,
            /* int256 localAssetCashFromLiquidator */
        ) = NOTIONAL.liquidatefCashCrossCurrency(
            liquidation.liquidateAccount,
            liquidation.localCurrency,
            liquidation.fCashCurrency,
            liquidation.fCashMaturities,
            liquidation.maxfCashLiquidateAmounts
        );

        // Redeem to underlying here, collateral is not specified as an input asset
        _sellfCashAssets(
            liquidation.fCashCurrency,
            liquidation.fCashMaturities,
            fCashNotionalTransfers,
            0,
            true
        );
        if (liquidation.fCashCurrency == Constants.ETH_CURRENCY_ID) {
            // Wrap everything to WETH for trading
            _wrapToWETH();
        }

        // NOTE: no withdraw if _hasTransferFees, _sellfCashAssets with withdraw everything
    }

    function _sellfCashAssets(
        uint16 fCashCurrency,
        uint256[] memory fCashMaturities,
        int256[] memory fCashNotional,
        uint256 depositActionAmount,
        bool redeemToUnderlying
    ) internal virtual;

    function _redeemAndWithdraw(
        uint16 nTokenCurrencyId,
        uint96 nTokenBalance,
        bool redeemToUnderlying
    ) internal virtual;

    function _wrapToWETH() internal {
        WETH9(WETH).deposit{value: address(this).balance}();
    }

    function _unwrapStakedETH() internal {
        wstETH.unwrap(wstETH.balanceOf(address(this)));
    }
}
