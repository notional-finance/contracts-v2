// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/PortfolioHandler.sol";
import "../storage/AccountContextHandler.sol";
import "../common/Liquidation.sol";
import "../storage/StorageLayoutV1.sol";
import "./BaseMockLiquidation.sol";

contract MockLiquidationSetup is BaseMockLiquidation {
    function preLiquidationActions(
        address liquidateAccount,
        uint localCurrency,
        uint collateralCurrency,
        uint blockTime
    ) external returns (AccountStorage memory, LiquidationFactors memory, PortfolioState memory) {
        return Liquidation.preLiquidationActions(liquidateAccount, localCurrency, collateralCurrency, blockTime);
    }
}

contract MockLocalLiquidation is BaseMockLiquidation {
    function liquidateLocalCurrency(
        address liquidateAccount,
        uint localCurrency,
        uint96 maxPerpetualTokenLiquidation,
        uint blockTime
    ) external returns (BalanceState memory, int, PortfolioState memory, MarketParameters[] memory) {
        (
            AccountStorage memory accountContext,
            LiquidationFactors memory factors,
            PortfolioState memory portfolio
        ) = Liquidation.preLiquidationActions(liquidateAccount, localCurrency, 0, blockTime);
        BalanceState memory liquidatedBalanceState = BalanceHandler.buildBalanceState(liquidateAccount, localCurrency, accountContext);

        int netLocalFromLiquidator = Liquidation.liquidateLocalCurrency(
            localCurrency,
            maxPerpetualTokenLiquidation,
            blockTime,
            liquidatedBalanceState,
            factors,
            portfolio
        );

        return (liquidatedBalanceState, netLocalFromLiquidator, portfolio, factors.markets);
    }
}

contract MockLocalLiquidationOverride is BaseMockLiquidation {
    function liquidateLocalCurrencyOverride(
        uint localCurrency,
        uint96 maxPerpetualTokenLiquidation,
        uint blockTime,
        BalanceState memory liquidatedBalanceState,
        LiquidationFactors memory factors
    ) external returns (BalanceState memory, int, MarketParameters[] memory) {
        PortfolioState memory portfolio;

        int netLocalFromLiquidator = Liquidation.liquidateLocalCurrency(
            localCurrency,
            maxPerpetualTokenLiquidation,
            blockTime,
            liquidatedBalanceState,
            factors,
            portfolio
        );

        return (liquidatedBalanceState, netLocalFromLiquidator, factors.markets);
    }
}

contract MockCollateralLiquidation is BaseMockLiquidation {
    function liquidateCollateralCurrency(
        BalanceState memory liquidatedBalanceState, 
        LiquidationFactors memory factors,
        PortfolioState memory portfolio,
        uint128 maxCollateralLiquidation,
        uint96 maxPerpetualTokenLiquidation,
        uint blockTime
    ) external returns (BalanceState memory, int, PortfolioState memory, MarketParameters[] memory) {
        int localToPurchase = Liquidation.liquidateCollateralCurrency(
            maxCollateralLiquidation,
            maxPerpetualTokenLiquidation,
            blockTime,
            liquidatedBalanceState,
            factors,
            portfolio
        );

        return (liquidatedBalanceState, localToPurchase, portfolio, factors.markets);
    }
}

contract MockfCashLiquidation is BaseMockLiquidation {

    function liquidatefCashLocal(
        address liquidateAccount,
        uint localCurrency,
        uint[] calldata fCashMaturities,
        uint[] calldata maxfCashLiquidateAmounts,
        Liquidation.fCashContext memory c,
        uint blockTime
    ) external returns (int[] memory, int, PortfolioState memory) {
        c.fCashNotionalTransfers = new int[](fCashMaturities.length);
        Liquidation.liquidatefCashLocal(
            liquidateAccount,
            localCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts,
            c,
            blockTime
        );

        return (c.fCashNotionalTransfers, c.localToPurchase, c.portfolio);
    }

    function liquidatefCashCrossCurrency(
        address liquidateAccount,
        uint collateralCurrency,
        uint[] calldata fCashMaturities,
        uint[] calldata maxfCashLiquidateAmounts,
        Liquidation.fCashContext memory c,
        uint blockTime
    ) external returns (int[] memory, int, PortfolioState memory) {
        c.fCashNotionalTransfers = new int[](fCashMaturities.length);

        Liquidation.liquidatefCashCrossCurrency(
            liquidateAccount,
            collateralCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts,
            c,
            blockTime
        );

        return (c.fCashNotionalTransfers, c.localToPurchase, c.portfolio);
    }

}