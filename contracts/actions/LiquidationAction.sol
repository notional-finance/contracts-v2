// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/Liquidation.sol";
import "../common/TransferAssets.sol";
import "../math/SafeInt256.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/BalanceHandler.sol";
import "../storage/AccountContextHandler.sol";

library LiquidationHelpers {
    using AccountContextHandler for AccountStorage;
    using PortfolioHandler for PortfolioState;
    using BalanceHandler for BalanceState;
    using SafeInt256 for int;

    function finalizeLiquidatorLocal(
        address liquidator,
        uint localCurrencyId,
        int netLocalFromLiquidator,
        int netLocalPerpetualTokens
    ) internal returns (AccountStorage memory) {
        // Liquidator must deposit netLocalFromLiquidator, in the case of a repo discount then the
        // liquidator will receive some positive amount
        Token memory token = TokenHandler.getToken(localCurrencyId, false);
        AccountStorage memory liquidatorContext = AccountContextHandler.getAccountContext(liquidator);
        BalanceState memory liquidatorLocalBalance = BalanceHandler.buildBalanceState(
            liquidator,
            localCurrencyId,
            liquidatorContext
        );

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
        liquidatorLocalBalance.netPerpetualTokenTransfer = netLocalPerpetualTokens;
        liquidatorLocalBalance.finalize(liquidator, liquidatorContext, false);

        return liquidatorContext;
    }

    function finalizeLiquidatorCollateral(
        address liquidator,
        AccountStorage memory liquidatorContext,
        uint collateralCurrencyId,
        int netCollateralToLiquidator,
        int netCollateralPerpetualTokens,
        bool withdrawCollateral,
        bool redeemToUnderlying
    ) internal returns (AccountStorage memory) {
        BalanceState memory liquidatorLocalBalance = BalanceHandler.buildBalanceState(
            liquidator,
            collateralCurrencyId,
            liquidatorContext
        );

        if (withdrawCollateral) {
            liquidatorLocalBalance.netAssetTransferInternalPrecision = netCollateralToLiquidator.neg();
        } else {
            liquidatorLocalBalance.netCashChange = netCollateralToLiquidator;
        }
        liquidatorLocalBalance.netPerpetualTokenTransfer = netCollateralPerpetualTokens;
        liquidatorLocalBalance.finalize(liquidator, liquidatorContext, redeemToUnderlying);

        return liquidatorContext;
    }

    function finalizeLiquidatedLocalBalance(
        address liquidateAccount,
        uint localCurrency,
        AccountStorage memory accountContext,
        int netLocalFromLiquidator
    ) internal {
        BalanceState memory localBalanceState = BalanceHandler.buildBalanceState(
            liquidateAccount,
            localCurrency,
            accountContext
        );
        localBalanceState.netCashChange = netLocalFromLiquidator;
        localBalanceState.finalize(liquidateAccount, accountContext, false);
    }

    function transferAssets(
        address liquidateAccount,
        address liquidator,
        AccountStorage memory liquidatorContext,
        uint fCashCurrency,
        uint[] calldata fCashMaturities,
        Liquidation.fCashContext memory c
    ) internal {
        PortfolioAsset[] memory assets = makeAssetArray(
            fCashCurrency,
            fCashMaturities,
            c.fCashNotionalTransfers
        );

        TransferAssets.placeAssetsInAccount(liquidator, liquidatorContext, assets);
        TransferAssets.invertNotionalAmountsInPlace(assets);

        if (c.accountContext.bitmapCurrencyId == 0) {
            c.portfolio.addMultipleAssets(assets);
            AccountContextHandler.storeAssetsAndUpdateContext(c.accountContext, liquidateAccount, c.portfolio);
        } else {
            BitmapAssetsHandler.addMultipleifCashAssets(liquidateAccount, c.accountContext, assets);
        }
    }

    function makeAssetArray(
        uint fCashCurrency,
        uint[] calldata fCashMaturities,
        int[] memory fCashNotionalTransfers
    ) internal pure returns (PortfolioAsset[] memory) {
        PortfolioAsset[] memory assets = new PortfolioAsset[](fCashMaturities.length);
        for (uint i; i < assets.length; i++) {
            assets[i].currencyId = fCashCurrency;
            assets[i].assetType = AssetHandler.FCASH_ASSET_TYPE;
            assets[i].notional = fCashNotionalTransfers[i];
            assets[i].maturity = fCashMaturities[i];
        }
    }
}

contract LiquidateLocalCurrency {
    using AccountContextHandler for AccountStorage;
    using BalanceHandler for BalanceState;
    using SafeInt256 for int;

    function liquidateLocalCurrency(
        address liquidateAccount,
        uint localCurrency,
        uint96 maxPerpetualTokenLiquidation
    ) external returns (int) {
        uint blockTime = block.timestamp;
        (
            AccountStorage memory accountContext,
            LiquidationFactors memory factors,
            PortfolioState memory portfolio
        ) = Liquidation.preLiquidationActions(liquidateAccount, localCurrency, 0, blockTime);
        BalanceState memory localBalanceState = BalanceHandler.buildBalanceState(liquidateAccount, localCurrency, accountContext);

        int netLocalFromLiquidator = Liquidation.liquidateLocalCurrency(
            localCurrency,
            maxPerpetualTokenLiquidation,
            blockTime,
            localBalanceState,
            factors,
            portfolio
        );

        AccountStorage memory liquidatorContext = LiquidationHelpers.finalizeLiquidatorLocal(
            msg.sender,
            localCurrency,
            netLocalFromLiquidator,
            localBalanceState.netPerpetualTokenTransfer.neg()
        );
        liquidatorContext.setAccountContext(msg.sender);

        // Finalize liquidated account balance
        localBalanceState.finalize(liquidateAccount, accountContext, false);
        if (accountContext.bitmapCurrencyId != 0) {
            // Portfolio updates only happen if the account has liquidity tokens, which can only be the
            // case in a non-bitmapped portfolio.
            // todo: set allow liquidation flag
            AccountContextHandler.storeAssetsAndUpdateContext(accountContext, liquidateAccount, portfolio);
        }
        accountContext.setAccountContext(liquidateAccount);

        return netLocalFromLiquidator;
    }
}

contract LiquidateCollateralCurrency {
    using AccountContextHandler for AccountStorage;
    using BalanceHandler for BalanceState;
    using SafeInt256 for int;

    function liquidateCollateralCurrency(
        address liquidateAccount,
        uint localCurrency,
        uint collateralCurrency,
        uint128 maxCollateralLiquidation,
        uint96 maxPerpetualTokenLiquidation,
        bool withdrawCollateral,
        bool redeemToUnderlying
    ) external returns (int) {
        uint blockTime = block.timestamp;
        (
            AccountStorage memory accountContext,
            LiquidationFactors memory factors,
            PortfolioState memory portfolio
        ) = Liquidation.preLiquidationActions(liquidateAccount, localCurrency, collateralCurrency, blockTime);
        BalanceState memory collateralBalanceState = BalanceHandler.buildBalanceState(
            liquidateAccount,
            collateralCurrency,
            accountContext
        );

        int netLocalFromLiquidator = Liquidation.liquidateCollateralCurrency(
            maxCollateralLiquidation,
            maxPerpetualTokenLiquidation,
            blockTime,
            collateralBalanceState,
            factors,
            portfolio
        );

        {
            AccountStorage memory liquidatorContext = LiquidationHelpers.finalizeLiquidatorLocal(
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
                collateralBalanceState.netPerpetualTokenTransfer.neg(),
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
            // todo: set allow liquidation flag
            AccountContextHandler.storeAssetsAndUpdateContext(accountContext, liquidateAccount, portfolio);
        }
        accountContext.setAccountContext(liquidateAccount);

        return netLocalFromLiquidator;
    }
}

contract LiquidatefCashLocal {
    using AccountContextHandler for AccountStorage;
    using SafeInt256 for int;

    function liquidatefCashLocal(
        address liquidateAccount,
        uint localCurrency,
        uint[] calldata fCashMaturities,
        uint[] calldata maxfCashLiquidateAmounts,
        uint blockTime
    ) external returns (int[] memory, int) {
        Liquidation.fCashContext memory c;
        (
            c.accountContext,
            c.factors,
            c.portfolio
        ) = Liquidation.preLiquidationActions(liquidateAccount, localCurrency, 0, blockTime);
        c.fCashNotionalTransfers = new int[](fCashMaturities.length);

        Liquidation.liquidatefCashLocal(
            liquidateAccount,
            localCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts,
            c,
            blockTime
        );

        AccountStorage memory liquidatorContext = LiquidationHelpers.finalizeLiquidatorLocal(
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
        c.accountContext.setAccountContext(msg.sender);

        return (c.fCashNotionalTransfers, c.localToPurchase);
    }
}

contract LiquidatefCashCrossCurrency {
    using AccountContextHandler for AccountStorage;
    using SafeInt256 for int;

    function liquidatefCashCrossCurrency(
        address liquidateAccount,
        uint localCurrency,
        uint collateralCurrency,
        uint[] calldata fCashMaturities,
        uint[] calldata maxfCashLiquidateAmounts,
        uint blockTime
    ) external returns (int[] memory, int) {
        Liquidation.fCashContext memory c;
        (
            c.accountContext,
            c.factors,
            c.portfolio
        ) = Liquidation.preLiquidationActions(liquidateAccount, localCurrency, 0, blockTime);
        c.fCashNotionalTransfers = new int[](fCashMaturities.length);

        Liquidation.liquidatefCashCrossCurrency(
            liquidateAccount,
            collateralCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts,
            c,
            blockTime
        );
        
        AccountStorage memory liquidatorContext = LiquidationHelpers.finalizeLiquidatorLocal(
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
        c.accountContext.setAccountContext(msg.sender);

        return (c.fCashNotionalTransfers, c.localToPurchase);
    }
}
