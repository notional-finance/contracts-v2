// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./NotionalV2BaseLiquidator.sol";
import "./NotionalV2UniV3SwapRouter.sol";
import "../../math/SafeInt256.sol";
import "../../../interfaces/notional/NotionalProxy.sol";
import "../../../interfaces/compound/CTokenInterface.sol";
import "../../../interfaces/compound/CErc20Interface.sol";
import "../../../interfaces/compound/CEtherInterface.sol";
import "../../../interfaces/aave/IFlashLender.sol";
import "../../../interfaces/aave/IFlashLoanReceiver.sol";
import "../../../interfaces/IWstETH.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

abstract contract NotionalV2FlashLiquidatorBase is NotionalV2BaseLiquidator, IFlashLoanReceiver {
    using SafeInt256 for int256;
    using SafeMath for uint256;

    address public immutable LENDING_POOL;
    address public immutable DEX_1;
    address public immutable DEX_2;

    constructor(
        NotionalProxy notionalV2_,
        address lendingPool_,
        address weth_,
        IWstETH wstETH_,
        address owner_,
        address dex1,
        address dex2
    ) NotionalV2BaseLiquidator(notionalV2_, weth_, wstETH_, owner_) {
        LENDING_POOL = lendingPool_;
        DEX_1 = dex1;
        DEX_2 = dex2;
    }

    function _enableCurrency(uint16 currencyId) internal override returns (address) {
        address underlying = super._enableCurrency(currencyId);
        // Lending pool needs to be able to pull underlying
        checkAllowanceOrSet(underlying, LENDING_POOL);

        if (DEX_1 != address(0)) {
            checkAllowanceOrSet(underlying, DEX_1);
        }

        if (DEX_2 != address(0)) {
            checkAllowanceOrSet(underlying, DEX_2);
        }

        return underlying;
    }

    // Profit estimation
    function flashLoan(address asset, uint256 amount, bytes calldata params, address collateralAddress) 
        external onlyOwner returns (uint256 localProfit, uint256 collateralProfit) {
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
        localProfit = IERC20(asset).balanceOf(address(this));
        collateralProfit = collateralAddress == address(0) ? 0 : IERC20(collateralAddress).balanceOf(address(this));
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

        // Mint cTokens for incoming assets, if required. If there are transfer fees
        // the we deposit underlying instead inside each _liquidate call instead
        if (!action.hasTransferFee) _mintCTokens(assets, amounts);

        if (LiquidationType(action.liquidationType) == LiquidationType.LocalCurrency) {
            _liquidateLocal(action, assets);
        } else if (LiquidationType(action.liquidationType) == LiquidationType.CollateralCurrency) {
            _liquidateCollateral(action, assets);
        } else if (LiquidationType(action.liquidationType) == LiquidationType.LocalfCash) {
            _liquidateLocalfCash(action, assets);
        } else if (LiquidationType(action.liquidationType) == LiquidationType.CrossCurrencyfCash) {
            _liquidateCrossCurrencyfCash(action, assets);
        }

        _redeemCTokens(assets);

        if (
            LiquidationType(action.liquidationType) == LiquidationType.CollateralCurrency ||
            LiquidationType(action.liquidationType) == LiquidationType.CrossCurrencyfCash
        ) {
            _dexTrade(action);
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
            _executeDexTrade(0, liquidation.tradeData);
        } else {
            CrossCurrencyfCashLiquidation memory liquidation = abi.decode(
                action.payload,
                (CrossCurrencyfCashLiquidation)
            );

            collateralUnderlyingAddress = liquidation.fCashUnderlyingAddress;
            _executeDexTrade(0, liquidation.tradeData);
        }

        if (action.withdrawProfit) {
            _withdrawProfit(collateralUnderlyingAddress, 0);
        }
    }

    function _executeDexTrade(uint256 ethValue, TradeData memory tradeData) internal {
        require(
            tradeData.dexAddress == DEX_1 || tradeData.dexAddress == DEX_2,
            "bad exchange address"
        );

        // prettier-ignore
        (bool success, /* return value */) = tradeData.dexAddress.call{value: ethValue}(tradeData.params);
        require(success, "dex trade failed");
    }
}
