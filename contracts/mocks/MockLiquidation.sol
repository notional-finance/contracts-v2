// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../internal/portfolio/PortfolioHandler.sol";
import "../internal/AccountContextHandler.sol";
import "../internal/Liquidation.sol";
import "../global/StorageLayoutV1.sol";
import "./BaseMockLiquidation.sol";

contract MockLiquidationSetup is BaseMockLiquidation {
    function preLiquidationActions(
        address liquidateAccount,
        uint256 localCurrency,
        uint256 collateralCurrency,
        uint256 blockTime
    )
        external
        returns (
            AccountContext memory,
            LiquidationFactors memory,
            PortfolioState memory
        )
    {
        return
            Liquidation.preLiquidationActions(
                liquidateAccount,
                localCurrency,
                collateralCurrency,
                blockTime
            );
    }
}

contract MockLocalLiquidation is BaseMockLiquidation {
    using BalanceHandler for BalanceState;

    function liquidateLocalCurrency(
        address liquidateAccount,
        uint256 localCurrency,
        uint96 maxPerpetualTokenLiquidation,
        uint256 blockTime
    )
        external
        returns (
            BalanceState memory,
            int256,
            PortfolioState memory,
            MarketParameters[] memory
        )
    {
        (
            AccountContext memory accountContext,
            LiquidationFactors memory factors,
            PortfolioState memory portfolio
        ) = Liquidation.preLiquidationActions(liquidateAccount, localCurrency, 0, blockTime);
        BalanceState memory liquidatedBalanceState;
        liquidatedBalanceState.loadBalanceState(liquidateAccount, localCurrency, accountContext);

        int256 netLocalFromLiquidator =
            Liquidation.liquidateLocalCurrency(
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
        uint256 localCurrency,
        uint96 maxPerpetualTokenLiquidation,
        uint256 blockTime,
        BalanceState memory liquidatedBalanceState,
        LiquidationFactors memory factors
    )
        external
        returns (
            BalanceState memory,
            int256,
            MarketParameters[] memory
        )
    {
        PortfolioState memory portfolio;

        int256 netLocalFromLiquidator =
            Liquidation.liquidateLocalCurrency(
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
        uint256 blockTime
    )
        external
        returns (
            BalanceState memory,
            int256,
            PortfolioState memory,
            MarketParameters[] memory
        )
    {
        int256 localToPurchase =
            Liquidation.liquidateCollateralCurrency(
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
        uint256 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        Liquidation.fCashContext memory c,
        uint256 blockTime
    )
        external
        returns (
            int256[] memory,
            int256,
            PortfolioState memory
        )
    {
        c.fCashNotionalTransfers = new int256[](fCashMaturities.length);
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
        uint256 collateralCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        Liquidation.fCashContext memory c,
        uint256 blockTime
    )
        external
        returns (
            int256[] memory,
            int256,
            PortfolioState memory
        )
    {
        c.fCashNotionalTransfers = new int256[](fCashMaturities.length);

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
