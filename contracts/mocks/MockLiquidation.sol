// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/PortfolioHandler.sol";
import "../storage/AccountContextHandler.sol";
import "../common/Liquidation.sol";
import "../storage/StorageLayoutV1.sol";
import "./BaseMockLiquidation.sol";

contract MockLocalLiquidation is BaseMockLiquidation {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;
    using Market for MarketParameters;

    function liquidateLocalCurrency(
        address liquidateAccount,
        uint localCurrency,
        uint96 maxPerpetualTokenLiquidation,
        uint blockTime
    ) external returns (BalanceState memory, int, PortfolioState memory) {
        return Liquidation.liquidateLocalCurrency(liquidateAccount, localCurrency, maxPerpetualTokenLiquidation, blockTime);
    }
}

contract MockCollateralLiquidation is BaseMockLiquidation {
    function liquidateCollateralCurrency(
        address liquidateAccount,
        uint localCurrency,
        uint collateralCurrency,
        uint128 maxCollateralLiquidation,
        uint96 maxPerpetualTokenLiquidation,
        uint blockTime
    ) external returns (BalanceState memory, int) {
        return Liquidation.liquidateCollateralCurrency(liquidateAccount, localCurrency,
            collateralCurrency, maxCollateralLiquidation, maxPerpetualTokenLiquidation, blockTime);
    }
}

contract MockfCashLiquidation is BaseMockLiquidation {

    function liquidatefCashLocal(
        address liquidateAccount,
        uint localCurrency,
        uint[] calldata fCashMaturities,
        uint[] calldata maxfCashLiquidateAmounts,
        uint blockTime
    ) external returns (int[] memory, int, PortfolioState memory) {
        return Liquidation.liquidatefCashLocal(liquidateAccount, localCurrency,
            fCashMaturities, maxfCashLiquidateAmounts, blockTime);
    }

    function liquidatefCashCrossCurrency(
        address liquidateAccount,
        uint localCurrency,
        uint collateralCurrency,
        uint[] calldata fCashMaturities,
        uint[] calldata maxfCashLiquidateAmounts,
        uint blockTime
    ) external returns (int[] memory, int, PortfolioState memory) {
        return Liquidation.liquidatefCashCrossCurrency(liquidateAccount, localCurrency,
            collateralCurrency, fCashMaturities, maxfCashLiquidateAmounts, blockTime);
    }

}