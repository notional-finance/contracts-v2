// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/AccountContextHandler.sol";
import "../../internal/liquidation/LiquidatefCash.sol";
import "../../internal/liquidation/LiquidationHelpers.sol";
import "../../math/SafeInt256.sol";

contract LiquidatefCashAction {
    using AccountContextHandler for AccountContext;
    using SafeInt256 for int256;

    function liquidatefCashLocal(
        address liquidateAccount,
        uint256 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        uint256 blockTime
    ) external returns (int256[] memory, int256) {
        LiquidatefCash.fCashContext memory c;
        (c.accountContext, c.factors, c.portfolio) = LiquidationHelpers.preLiquidationActions(
            liquidateAccount,
            localCurrency,
            0
        );
        c.fCashNotionalTransfers = new int256[](fCashMaturities.length);

        LiquidatefCash.liquidatefCashLocal(
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
        LiquidatefCash.fCashContext memory c;
        (c.accountContext, c.factors, c.portfolio) = LiquidationHelpers.preLiquidationActions(
            liquidateAccount,
            localCurrency,
            0
        );
        c.fCashNotionalTransfers = new int256[](fCashMaturities.length);

        LiquidatefCash.liquidatefCashCrossCurrency(
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
