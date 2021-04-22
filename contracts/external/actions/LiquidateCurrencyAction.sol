// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/AccountContextHandler.sol";
import "../../internal/liquidation/LiquidateCurrency.sol";
import "../../internal/liquidation/LiquidationHelpers.sol";
import "../../math/SafeInt256.sol";

contract LiquidateCurrencyAction {
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;
    using SafeInt256 for int256;

    function liquidateLocalCurrency(
        address liquidateAccount,
        uint256 localCurrency,
        uint96 maxNTokenLiquidation
    ) external returns (int256) {
        uint256 blockTime = block.timestamp;
        (
            AccountContext memory accountContext,
            LiquidationFactors memory factors,
            PortfolioState memory portfolio
        ) = LiquidationHelpers.preLiquidationActions(liquidateAccount, localCurrency, 0);
        BalanceState memory localBalanceState;
        localBalanceState.loadBalanceState(liquidateAccount, localCurrency, accountContext);

        int256 netLocalFromLiquidator =
            LiquidateCurrency.liquidateLocalCurrency(
                localCurrency,
                maxNTokenLiquidation,
                blockTime,
                localBalanceState,
                factors,
                portfolio
            );

        // Transfers a positive or negative amount of local currency as well as the net nToken
        // amounts to the liquidator
        AccountContext memory liquidatorContext =
            LiquidationHelpers.finalizeLiquidatorLocal(
                msg.sender,
                localCurrency,
                netLocalFromLiquidator,
                localBalanceState.netNTokenTransfer.neg()
            );
        liquidatorContext.setAccountContext(msg.sender);

        LiquidateCurrency.finalizeLiquidatedCollateralAndPortfolio(
            liquidateAccount,
            localBalanceState, // In this case, local currency is the collateral
            accountContext,
            portfolio,
            factors.markets
        );

        return netLocalFromLiquidator;
    }

    function liquidateCollateralCurrency(
        address liquidateAccount,
        uint256 localCurrency,
        uint256 collateralCurrency,
        uint128 maxCollateralLiquidation,
        uint96 maxNTokenLiquidation,
        bool withdrawCollateral,
        bool redeemToUnderlying
    ) external returns (int256) {
        uint256 blockTime = block.timestamp;
        (
            AccountContext memory accountContext,
            LiquidationFactors memory factors,
            PortfolioState memory portfolio
        ) =
            LiquidationHelpers.preLiquidationActions(
                liquidateAccount,
                localCurrency,
                collateralCurrency
            );
        BalanceState memory collateralBalanceState;
        collateralBalanceState.loadBalanceState(
            liquidateAccount,
            collateralCurrency,
            accountContext
        );

        int256 netLocalFromLiquidator =
            LiquidateCurrency.liquidateCollateralCurrency(
                maxCollateralLiquidation,
                maxNTokenLiquidation,
                blockTime,
                collateralBalanceState,
                factors,
                portfolio
            );

        {
            // Will transfer local currency from the liquidator
            AccountContext memory liquidatorContext =
                LiquidationHelpers.finalizeLiquidatorLocal(
                    msg.sender,
                    localCurrency,
                    netLocalFromLiquidator,
                    0 // No nToken transfers
                );

            // Will transfer collateral to the liquidator
            LiquidationHelpers.finalizeLiquidatorCollateral(
                msg.sender,
                liquidatorContext,
                collateralCurrency,
                collateralBalanceState.netCashChange.neg(),
                collateralBalanceState.netNTokenTransfer.neg(),
                withdrawCollateral,
                redeemToUnderlying
            );

            liquidatorContext.setAccountContext(msg.sender);
        }

        // Local account balance will increase by the net paid from the liquidator
        LiquidationHelpers.finalizeLiquidatedLocalBalance(
            liquidateAccount,
            localCurrency,
            accountContext,
            netLocalFromLiquidator
        );

        LiquidateCurrency.finalizeLiquidatedCollateralAndPortfolio(
            liquidateAccount,
            collateralBalanceState,
            accountContext,
            portfolio,
            factors.markets
        );

        return netLocalFromLiquidator;
    }
}
