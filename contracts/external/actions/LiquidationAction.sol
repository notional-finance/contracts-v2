// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/AccountContextHandler.sol";
import "../../internal/Liquidation.sol";
import "../../internal/portfolio/TransferAssets.sol";
import "../../internal/portfolio/PortfolioHandler.sol";
import "../../internal/balances/BalanceHandler.sol";
import "../../math/SafeInt256.sol";

library LiquidationHelpers {
    using AccountContextHandler for AccountContext;
    using PortfolioHandler for PortfolioState;
    using BalanceHandler for BalanceState;
    using SafeInt256 for int256;

    function finalizeLiquidatorLocal(
        address liquidator,
        uint256 localCurrencyId,
        int256 netLocalFromLiquidator,
        int256 netLocalPerpetualTokens
    ) internal returns (AccountContext memory) {
        // Liquidator must deposit netLocalFromLiquidator, in the case of a repo discount then the
        // liquidator will receive some positive amount
        Token memory token = TokenHandler.getToken(localCurrencyId, false);
        AccountContext memory liquidatorContext =
            AccountContextHandler.getAccountContext(liquidator);
        // TODO: maybe reuse these...
        BalanceState memory liquidatorLocalBalance;
        liquidatorLocalBalance.loadBalanceState(liquidator, localCurrencyId, liquidatorContext);

        if (token.hasTransferFee && netLocalFromLiquidator > 0) {
            // If a token has a transfer fee then it must have been deposited prior to the liquidation
            // or else we won't be able to net off the correct amount. We also require that the account
            // does not have debt so that we do not have to run a free collateral check here
            require(
                liquidatorLocalBalance.storedCashBalance >= netLocalFromLiquidator &&
                    liquidatorContext.hasDebt == 0x00,
                "Token transfer unavailable"
            );
            liquidatorLocalBalance.netCashChange = netLocalFromLiquidator.neg();
        } else {
            liquidatorLocalBalance.netAssetTransferInternalPrecision = netLocalFromLiquidator;
        }
        liquidatorLocalBalance.netNTokenTransfer = netLocalPerpetualTokens;
        liquidatorLocalBalance.finalize(liquidator, liquidatorContext, false);

        return liquidatorContext;
    }

    function finalizeLiquidatorCollateral(
        address liquidator,
        AccountContext memory liquidatorContext,
        uint256 collateralCurrencyId,
        int256 netCollateralToLiquidator,
        int256 netCollateralPerpetualTokens,
        bool withdrawCollateral,
        bool redeemToUnderlying
    ) internal returns (AccountContext memory) {
        // TODO: maybe reuse these...
        BalanceState memory balance;
        balance.loadBalanceState(liquidator, collateralCurrencyId, liquidatorContext);

        if (withdrawCollateral) {
            balance.netAssetTransferInternalPrecision = netCollateralToLiquidator.neg();
        } else {
            balance.netCashChange = netCollateralToLiquidator;
        }
        balance.netNTokenTransfer = netCollateralPerpetualTokens;
        balance.finalize(liquidator, liquidatorContext, redeemToUnderlying);

        return liquidatorContext;
    }

    function finalizeLiquidatedLocalBalance(
        address liquidateAccount,
        uint256 localCurrency,
        AccountContext memory accountContext,
        int256 netLocalFromLiquidator
    ) internal {
        BalanceState memory balance;
        balance.loadBalanceState(liquidateAccount, localCurrency, accountContext);
        balance.netCashChange = netLocalFromLiquidator;
        balance.finalize(liquidateAccount, accountContext, false);
    }

    function transferAssets(
        address liquidateAccount,
        address liquidator,
        AccountContext memory liquidatorContext,
        uint256 fCashCurrency,
        uint256[] calldata fCashMaturities,
        Liquidation.fCashContext memory c
    ) internal {
        PortfolioAsset[] memory assets =
            makeAssetArray(fCashCurrency, fCashMaturities, c.fCashNotionalTransfers);

        TransferAssets.placeAssetsInAccount(liquidator, liquidatorContext, assets);
        TransferAssets.invertNotionalAmountsInPlace(assets);

        if (c.accountContext.bitmapCurrencyId == 0) {
            c.portfolio.addMultipleAssets(assets);
            AccountContextHandler.storeAssetsAndUpdateContext(
                c.accountContext,
                liquidateAccount,
                c.portfolio,
                false // Although this is liquidation, we should not allow past max assets here
            );
        } else {
            BitmapAssetsHandler.addMultipleifCashAssets(liquidateAccount, c.accountContext, assets);
        }
    }

    function makeAssetArray(
        uint256 fCashCurrency,
        uint256[] calldata fCashMaturities,
        int256[] memory fCashNotionalTransfers
    ) internal pure returns (PortfolioAsset[] memory) {
        PortfolioAsset[] memory assets = new PortfolioAsset[](fCashMaturities.length);
        for (uint256 i; i < assets.length; i++) {
            assets[i].currencyId = fCashCurrency;
            assets[i].assetType = Constants.FCASH_ASSET_TYPE;
            assets[i].notional = fCashNotionalTransfers[i];
            assets[i].maturity = fCashMaturities[i];
        }
    }
}

contract LiquidateCurrency {
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
        ) = Liquidation.preLiquidationActions(liquidateAccount, localCurrency, 0);
        BalanceState memory localBalanceState;
        localBalanceState.loadBalanceState(liquidateAccount, localCurrency, accountContext);

        int256 netLocalFromLiquidator =
            Liquidation.liquidateLocalCurrency(
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
        ) = Liquidation.preLiquidationActions(liquidateAccount, localCurrency, collateralCurrency);
        BalanceState memory collateralBalanceState;
        collateralBalanceState.loadBalanceState(
            liquidateAccount,
            collateralCurrency,
            accountContext
        );

        int256 netLocalFromLiquidator =
            Liquidation.liquidateCollateralCurrency(
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

contract LiquidatefCash {
    using AccountContextHandler for AccountContext;
    using SafeInt256 for int256;

    function liquidatefCashLocal(
        address liquidateAccount,
        uint256 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        uint256 blockTime
    ) external returns (int256[] memory, int256) {
        Liquidation.fCashContext memory c;
        (c.accountContext, c.factors, c.portfolio) = Liquidation.preLiquidationActions(
            liquidateAccount,
            localCurrency,
            0
        );
        c.fCashNotionalTransfers = new int256[](fCashMaturities.length);

        Liquidation.liquidatefCashLocal(
            liquidateAccount,
            localCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts,
            c,
            blockTime
        );

        AccountContext memory liquidatorContext =
            LiquidationHelpers.finalizeLiquidatorLocal(
                msg.sender,
                localCurrency,
                c.localToPurchase.neg(),
                0
            );

        LiquidationHelpers.finalizeLiquidatedLocalBalance(
            liquidateAccount,
            localCurrency,
            c.accountContext,
            c.localToPurchase
        );

        LiquidationHelpers.transferAssets(
            liquidateAccount,
            msg.sender,
            liquidatorContext,
            localCurrency,
            fCashMaturities,
            c
        );

        liquidatorContext.setAccountContext(msg.sender);
        c.accountContext.setAccountContext(liquidateAccount);

        return (c.fCashNotionalTransfers, c.localToPurchase);
    }

    function liquidatefCashCrossCurrency(
        address liquidateAccount,
        uint256 localCurrency,
        uint256 collateralCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        uint256 blockTime
    ) external returns (int256[] memory, int256) {
        Liquidation.fCashContext memory c;
        (c.accountContext, c.factors, c.portfolio) = Liquidation.preLiquidationActions(
            liquidateAccount,
            localCurrency,
            0
        );
        c.fCashNotionalTransfers = new int256[](fCashMaturities.length);

        Liquidation.liquidatefCashCrossCurrency(
            liquidateAccount,
            collateralCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts,
            c,
            blockTime
        );

        AccountContext memory liquidatorContext =
            LiquidationHelpers.finalizeLiquidatorLocal(
                msg.sender,
                localCurrency,
                c.localToPurchase.neg(),
                0
            );

        LiquidationHelpers.finalizeLiquidatedLocalBalance(
            liquidateAccount,
            localCurrency,
            c.accountContext,
            c.localToPurchase
        );

        LiquidationHelpers.transferAssets(
            liquidateAccount,
            msg.sender,
            liquidatorContext,
            collateralCurrency,
            fCashMaturities,
            c
        );

        liquidatorContext.setAccountContext(msg.sender);
        c.accountContext.setAccountContext(liquidateAccount);

        return (c.fCashNotionalTransfers, c.localToPurchase);
    }
}
