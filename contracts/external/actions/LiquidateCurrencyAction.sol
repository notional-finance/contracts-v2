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

        AccountContext memory liquidatorContext =
            LiquidationHelpers.finalizeLiquidatorLocal(
                msg.sender,
                localCurrency,
                netLocalFromLiquidator,
                localBalanceState.netNTokenTransfer.neg()
            );
        liquidatorContext.setAccountContext(msg.sender);

        // Finalize liquidated account balance
        localBalanceState.finalize(liquidateAccount, accountContext, false);
        if (accountContext.bitmapCurrencyId != 0) {
            // Portfolio updates only happen if the account has liquidity tokens, which can only be the
            // case in a non-bitmapped portfolio.
            AccountContextHandler.storeAssetsAndUpdateContext(
                accountContext,
                liquidateAccount,
                portfolio,
                true // is liquidation
            );
        }
        accountContext.setAccountContext(liquidateAccount);

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
            AccountContext memory liquidatorContext =
                LiquidationHelpers.finalizeLiquidatorLocal(
                    msg.sender,
                    localCurrency,
                    netLocalFromLiquidator,
                    0
                );

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

        // Finalize liquidated account balance
        LiquidationHelpers.finalizeLiquidatedLocalBalance(
            liquidateAccount,
            localCurrency,
            accountContext,
            netLocalFromLiquidator
        );
        collateralBalanceState.finalize(liquidateAccount, accountContext, false);
        if (accountContext.bitmapCurrencyId != 0) {
            // Portfolio updates only happen if the account has liquidity tokens, which can only be the
            // case in a non-bitmapped portfolio.
            AccountContextHandler.storeAssetsAndUpdateContext(
                accountContext,
                liquidateAccount,
                portfolio,
                true // is liquidation
            );
        }
        accountContext.setAccountContext(liquidateAccount);

        return netLocalFromLiquidator;
    }
}
