// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./NotionalV2BaseLiquidator.sol";
import "../../internal/markets/DateTime.sol";
import "../../math/SafeInt256.sol";
import "interfaces/notional/NotionalProxy.sol";
import "interfaces/compound/CTokenInterface.sol";
import "interfaces/compound/CErc20Interface.sol";
import "interfaces/compound/CEtherInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

interface IFlashLoanReceiver {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);

    //   function ADDRESSES_PROVIDER() external view returns (address);

    //   function LENDING_POOL() external view returns (address);
}

interface IFlashLender {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

abstract contract NotionalV2FlashLiquidator is NotionalV2BaseLiquidator, IFlashLoanReceiver {
    using SafeInt256 for int256;
    using SafeMath for uint256;

    address public LENDING_POOL;
    address public ADDRESS_PROVIDER;

    function __NotionalV2FlashLiquidator_init(
        NotionalProxy notionalV2_,
        address lendingPool_,
        address addressProvider_,
        address weth_,
        address cETH_,
        address owner_
    ) internal initializer {
        __NotionalV2BaseLiquidator_init(notionalV2_, weth_, cETH_, owner_);
        LENDING_POOL = lendingPool_;
        ADDRESS_PROVIDER = addressProvider_;
    }

    function setCTokenAddress(address cToken) external onlyOwner {
        address underlying = CTokenInterface(cToken).underlying();
        // Notional V2 needs to be able to pull cTokens
        checkAllowanceOrSet(cToken, address(NotionalV2));
        // Lending pool needs to be able to pull underlying
        checkAllowanceOrSet(underlying, LENDING_POOL);
        underlyingToCToken[underlying] = cToken;
    }

    function approveToken(address token, address spender) external onlyOwner {
        IERC20(token).approve(spender, type(uint256).max);
    }

    // Profit estimation
    function flashLoan(
        address flashLender,
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external returns (uint256) {
        require(msg.sender == OWNER, "Contract owner required");
        IFlashLender(flashLender).flashLoan(
            receiverAddress,
            assets,
            amounts,
            modes,
            onBehalfOf,
            params,
            referralCode
        );
        return IERC20(assets[0]).balanceOf(address(this));
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == LENDING_POOL); // dev: unauthorized caller
        LiquidationAction action = LiquidationAction(abi.decode(params, (uint8)));

        // Mint cTokens for incoming assets, if required. If there are transfer fees
        // the we deposit underlying instead inside each _liquidate call instead
        if (!_hasTransferFees(action)) _mintCTokens(assets, amounts);

        if (
            action == LiquidationAction.LocalCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.LocalCurrency_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.LocalCurrency_NoTransferFee_Withdraw ||
            action == LiquidationAction.LocalCurrency_NoTransferFee_NoWithdraw
        ) {
            _liquidateLocal(action, params, assets);
        } else if (
            action == LiquidationAction.CollateralCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_NoWithdraw
        ) {
            _liquidateCollateral(action, params, assets);
        } else if (
            action == LiquidationAction.LocalfCash_WithTransferFee_Withdraw ||
            action == LiquidationAction.LocalfCash_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.LocalfCash_NoTransferFee_Withdraw ||
            action == LiquidationAction.LocalfCash_NoTransferFee_NoWithdraw
        ) {
            _liquidateLocalfCash(action, params, assets);
        } else if (
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee_Withdraw ||
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.CrossCurrencyfCash_NoTransferFee_Withdraw ||
            action == LiquidationAction.CrossCurrencyfCash_NoTransferFee_NoWithdraw
        ) {
            _liquidateCrossCurrencyfCash(action, params, assets);
        }

        _redeemCTokens(assets);

        if (
            action == LiquidationAction.CollateralCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_NoWithdraw ||
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee_Withdraw ||
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.CrossCurrencyfCash_NoTransferFee_Withdraw ||
            action == LiquidationAction.CrossCurrencyfCash_NoTransferFee_NoWithdraw
        ) {
            _executeDexTrade(
                action,
                assets[0],
                amounts[0].add(premiums[0]), // Amount needed to pay back flash loan
                params
            );
        }

        if (
            action == LiquidationAction.LocalCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.LocalCurrency_NoTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_Withdraw ||
            action == LiquidationAction.LocalfCash_WithTransferFee_Withdraw ||
            action == LiquidationAction.LocalfCash_NoTransferFee_Withdraw ||
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee_Withdraw ||
            action == LiquidationAction.CrossCurrencyfCash_NoTransferFee_Withdraw
        ) {
            // Transfer profits to OWNER
            uint256 bal = IERC20(assets[0]).balanceOf(address(this));
            if (bal > amounts[0].add(premiums[0])) {
                IERC20(assets[0]).transfer(OWNER, bal.sub(amounts[0].add(premiums[0])));
            }
        }

        // The lending pool should have enough approval to pull the required amount from the contract
        return true;
    }

    function _executeDexTrade(
        LiquidationAction action,
        address to,
        uint256 amountOutMin,
        bytes calldata params
    ) internal {
        address collateralUnderlyingAddress;
        bytes memory tradeCallData;

        if (
            action == LiquidationAction.CollateralCurrency_WithTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_WithTransferFee_NoWithdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_Withdraw ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee_NoWithdraw
        ) {
            // prettier-ignore
            (
                /* uint8 action */,
                /* address liquidateAccount */,
                /* uint256 localCurrency */,
                /* address localCurrencyAddress */,
                /* uint256 collateralCurrency */,
                /* address collateralAddress, */,
                collateralUnderlyingAddress,
                /* uint128 maxCollateralLiquidation */,
                /* uint96 maxNTokenLiquidation */,
                tradeCallData
            ) = abi.decode(params, (uint8, address, uint256, address, uint256, address, address, uint128, uint96, bytes));
        } else {
            // prettier-ignore
            (
                /* uint8 action */,
                /* address liquidateAccount */,
                /* uint256 localCurrency*/,
                /* address localCurrencyAddress */,
                /* uint256 collateralCurrency */,
                /* address collateralAddress, */,
                collateralUnderlyingAddress,
                /* fCashMaturities */,
                /* maxfCashLiquidateAmounts */,
                tradeCallData
            ) = abi.decode(params, (uint8, address, uint256, address, uint256, address, address, uint256[], uint256[], bytes));
        }

        executeDexTrade(
            collateralUnderlyingAddress,
            to,
            IERC20(collateralUnderlyingAddress).balanceOf(address(this)),
            amountOutMin,
            tradeCallData
        );
    }

    function _liquidateLocalfCash(
        LiquidationAction action,
        bytes calldata params,
        address[] calldata assets
    ) internal {
        // prettier-ignore
        (
            /* uint8 action */,
            address liquidateAccount,
            uint16 localCurrency,
            uint256[] memory fCashMaturities,
            uint256[] memory maxfCashLiquidateAmounts
        ) = abi.decode(params, (uint8, address, uint16, uint256[], uint256[]));

        if (_hasTransferFees(action)) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            uint256 amount = IERC20(assets[0]).balanceOf(address(this));
            checkAllowanceOrSet(assets[0], address(NotionalV2));
            NotionalV2.depositUnderlyingToken(address(this), localCurrency, amount);
        }

        // prettier-ignore
        (
            int256[] memory fCashNotionalTransfers,
            int256 localAssetCashFromLiquidator
        ) = NotionalV2.liquidatefCashLocal(
            liquidateAccount,
            localCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts
        );

        // If localAssetCashFromLiquidator is negative (meaning the liquidator has received cash)
        // then when we will need to lend in order to net off the negative fCash. In this case we
        // will deposit the local asset cash back into notional.
        _sellfCashAssets(
            localCurrency,
            fCashMaturities,
            fCashNotionalTransfers,
            localAssetCashFromLiquidator < 0 ? uint256(localAssetCashFromLiquidator.abs()) : 0,
            false // No need to redeem to underlying here
        );

        // NOTE: no withdraw if _hasTransferFees, _sellfCashAssets with withdraw everything
    }

    function _liquidateCrossCurrencyfCash(
        LiquidationAction action,
        bytes calldata params,
        address[] calldata assets
    ) internal {
        // prettier-ignore
        (
            /* bytes1 action */,
            address liquidateAccount,
            uint16 localCurrency,
            /* address localAddress */,
            uint16 fCashCurrency,
            /* address fCashAddress */,
            /* address fCashUnderlyingAddress */,
            uint256[] memory fCashMaturities,
            uint256[] memory maxfCashLiquidateAmounts
        ) = abi.decode(params, 
            (uint8, address, uint16, address, uint16, address, address, uint256[], uint256[])
        );

        if (_hasTransferFees(action)) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            uint256 amount = IERC20(assets[0]).balanceOf(address(this));
            checkAllowanceOrSet(assets[0], address(NotionalV2));
            NotionalV2.depositUnderlyingToken(address(this), localCurrency, amount);
        }

        // prettier-ignore
        (
            int256[] memory fCashNotionalTransfers,
            /* int256 localAssetCashFromLiquidator */
        ) = NotionalV2.liquidatefCashCrossCurrency(
            liquidateAccount,
            localCurrency,
            fCashCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts
        );

        // Redeem to underlying here, collateral is not specified as an input asset
        _sellfCashAssets(fCashCurrency, fCashMaturities, fCashNotionalTransfers, 0, true);
        // Wrap everything to WETH for trading
        if (fCashCurrency == 1) WETH9(WETH).deposit{value: address(this).balance}();

        // NOTE: no withdraw if _hasTransferFees, _sellfCashAssets with withdraw everything
    }

    function _sellfCashAssets(
        uint16 fCashCurrency,
        uint256[] memory fCashMaturities,
        int256[] memory fCashNotional,
        uint256 depositActionAmount,
        bool redeemToUnderlying
    ) internal {
        uint256 blockTime = block.timestamp;
        BalanceActionWithTrades[] memory action = new BalanceActionWithTrades[](1);
        action[0].actionType = depositActionAmount > 0
            ? DepositActionType.DepositAsset
            : DepositActionType.None;
        action[0].depositActionAmount = depositActionAmount;
        action[0].currencyId = fCashCurrency;
        action[0].withdrawEntireCashBalance = true;
        action[0].redeemToUnderlying = redeemToUnderlying;

        uint256 numTrades;
        bytes32[] memory trades = new bytes32[](fCashMaturities.length);
        for (uint256 i; i < fCashNotional.length; i++) {
            if (fCashNotional[i] == 0) continue;
            (uint256 marketIndex, bool isIdiosyncratic) = DateTime.getMarketIndex(
                7,
                fCashMaturities[i],
                blockTime
            );
            // We don't trade it out here but if the contract does take on idiosyncratic cash we need to be careful
            if (isIdiosyncratic) continue;

            trades[numTrades] = bytes32(
                (uint256(fCashNotional[i] > 0 ? TradeActionType.Borrow : TradeActionType.Lend) <<
                    248) |
                    (marketIndex << 240) |
                    (uint256(uint88(fCashNotional[i].abs())) << 152)
            );
            numTrades++;
        }

        if (numTrades < trades.length) {
            // Shrink the trades array to length if it is not full
            bytes32[] memory newTrades = new bytes32[](numTrades);
            for (uint256 i; i < numTrades; i++) {
                newTrades[i] = trades[i];
            }
            action[0].trades = newTrades;
        } else {
            action[0].trades = trades;
        }

        NotionalV2.batchBalanceAndTradeAction(address(this), action);
    }

    function wrap() public {
        WETH9(WETH).deposit{value: address(this).balance}();
    }

    function withdraw(address token, uint256 amount) public {
        IERC20(token).transfer(OWNER, amount);
    }

    receive() external payable {}
}
