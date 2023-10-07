// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {
    BaseLiquidator, 
    LiquidationType,
    LiquidationAction, 
    TradeData,
    CollateralCurrencyLiquidation,
    CrossCurrencyfCashLiquidation
} from "./BaseLiquidator.sol";
import {TradeHandler, Trade} from "./TradeHandler.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {NotionalProxy} from "../../../interfaces/notional/NotionalProxy.sol";
import {ITradingModule} from "../../../interfaces/notional/ITradingModule.sol";
import {IFlashLender} from "../../../interfaces/aave/IFlashLender.sol";
import {IFlashLoanReceiver} from "../../../interfaces/aave/IFlashLoanReceiver.sol";
import {IWstETH} from "../../../interfaces/IWstETH.sol";

abstract contract FlashLiquidatorBase is BaseLiquidator, IFlashLoanReceiver {
    using SafeInt256 for int256;
    using SafeMath for uint256;
    using TradeHandler for Trade;

    address public immutable LENDING_POOL;
    ITradingModule public immutable TRADING_MODULE;

    constructor(
        NotionalProxy notional_,
        address lendingPool_,
        address weth_,
        IWstETH wstETH_,
        address owner_,
        address tradingModule_,
        bool unwrapStETH_
    ) BaseLiquidator(notional_, weth_, wstETH_, owner_, unwrapStETH_) {
        LENDING_POOL = lendingPool_;
        TRADING_MODULE = ITradingModule(tradingModule_);
    }

    function _enableCurrency(uint16 currencyId) internal override returns (address) {
        address underlying = super._enableCurrency(currencyId);

        if (underlying == Constants.ETH_ADDRESS) {
            underlying = address(WETH);
        }
        
        // Lending pool needs to be able to pull underlying
        checkAllowanceOrSet(underlying, LENDING_POOL);

        return underlying;
    }

    // Profit estimation
    function flashLoan(
        address asset, 
        uint256 amount, 
        bytes calldata params, 
        address localAddress, 
        address collateralAddress
    ) external onlyOwner returns (uint256 flashLoanResidual, uint256 localProfit, uint256 collateralProfit) {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        assets[0] = asset;
        amounts[0] = amount;

        IFlashLender(LENDING_POOL).flashLoan(
            address(this),
            assets,
            amounts,
            new uint256[](1),
            address(this),
            params,
            0
        );
        flashLoanResidual = IERC20(asset).balanceOf(address(this));
        localProfit = localAddress == address(0) ? 
            address(this).balance : IERC20(localAddress).balanceOf(address(this));
        collateralProfit = collateralAddress == address(0) ? 
            address(this).balance : IERC20(collateralAddress).balanceOf(address(this));
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == LENDING_POOL); // dev: unauthorized caller
        LiquidationAction memory action = abi.decode(params, ((LiquidationAction)));

        if (assets[0] == address(WETH)) {
            WETH.withdraw(amounts[0]);
        }

        if (action.preLiquidationTrade.length > 0) {
            TradeData memory tradeData = abi.decode(action.preLiquidationTrade, (TradeData));
            _executeDexTrade(tradeData);
        }

        if (LiquidationType(action.liquidationType) == LiquidationType.LocalCurrency) {
            _liquidateLocal(action, assets);
        } else if (LiquidationType(action.liquidationType) == LiquidationType.CollateralCurrency) {
            _liquidateCollateral(action, assets);
        } else if (LiquidationType(action.liquidationType) == LiquidationType.LocalfCash) {
            _liquidateLocalfCash(action, assets);
        } else if (LiquidationType(action.liquidationType) == LiquidationType.CrossCurrencyfCash) {
            _liquidateCrossCurrencyfCash(action, assets);
        }

        if (action.tradeInWETH) {
            WETH.deposit{value: address(this).balance}();
        }

        if (
            LiquidationType(action.liquidationType) == LiquidationType.CollateralCurrency ||
            LiquidationType(action.liquidationType) == LiquidationType.CrossCurrencyfCash
        ) {
            _dexTrade(action);
        }

        if (!action.tradeInWETH && assets[0] == address(WETH)) {
            WETH.deposit{value: address(this).balance}();
        }

        if (action.withdrawProfit) {
            _withdrawProfit(assets[0], amounts[0].add(premiums[0]));
        }

        // The lending pool should have enough approval to pull the required amount from the contract
        return true;
    }

    function _withdrawProfit(address currency, uint256 threshold) internal {
        // Transfer profit to OWNER
        uint256 bal = IERC20(currency).balanceOf(address(this));
        if (bal > threshold) {
            IERC20(currency).transfer(owner, bal.sub(threshold));
        }
    }

    function _dexTrade(LiquidationAction memory action) internal {
        address collateralUnderlyingAddress;

        if (LiquidationType(action.liquidationType) == LiquidationType.CollateralCurrency) {
            CollateralCurrencyLiquidation memory liquidation = abi.decode(
                action.payload,
                (CollateralCurrencyLiquidation)
            );

            collateralUnderlyingAddress = liquidation.collateralUnderlyingAddress;
            _executeDexTrade(liquidation.tradeData);
        } else {
            CrossCurrencyfCashLiquidation memory liquidation = abi.decode(
                action.payload,
                (CrossCurrencyfCashLiquidation)
            );

            collateralUnderlyingAddress = liquidation.fCashUnderlyingAddress;
            _executeDexTrade(liquidation.tradeData);
        }

        if (action.withdrawProfit) {
            _withdrawProfit(collateralUnderlyingAddress, 0);
        }
    }

    function _executeDexTrade(TradeData memory tradeData) internal {
        if (tradeData.useDynamicSlippage) {
            tradeData.trade._executeTradeWithDynamicSlippage({
                dexId: tradeData.dexId,
                tradingModule: TRADING_MODULE,
                dynamicSlippageLimit: tradeData.dynamicSlippageLimit
            });
        } else {
            tradeData.trade._executeTrade({
                dexId: tradeData.dexId,
                tradingModule: TRADING_MODULE
            });
        }
    }
}
