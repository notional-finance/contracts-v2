// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/Liquidation.sol";
import "../storage/StorageLayoutV1.sol";

contract MockLiquidation is StorageLayoutV1 {
    using Liquidation for LiquidationFactors;
    using Market for MarketParameters;

    function setAssetRateMapping(
        uint id,
        AssetRateStorage calldata rs
    ) external {
        assetToUnderlyingRateMapping[id] = rs;
    }

    function setETHRateMapping(
        uint id,
        ETHRateStorage calldata rs
    ) external {
        underlyingToETHRateMapping[id] = rs;
    }

    function setMarketState(MarketParameters memory ms) external {
        ms.setMarketStorage();
    }

    function getLiquidationFactors(
        uint localCurrencyId,
        uint collateralCurrencyId,
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates,
        int[] memory netPortfolioValue
    ) public returns (LiquidationFactors memory) {
        LiquidationFactors memory factors = Liquidation.getLiquidationFactorsStateful(
            localCurrencyId,
            collateralCurrencyId,
            balanceState,
            cashGroups,
            marketStates,
            netPortfolioValue
        );

        assert(factors.localCashGroup.currencyId == localCurrencyId);
        assert(factors.collateralCashGroup.currencyId == collateralCurrencyId);

        return factors;
    }

    function liquidateLocalLiquidityTokens(
        LiquidationFactors memory factors,
        uint blockTime,
        BalanceState memory localBalanceContext,
        PortfolioState memory portfolioState
    ) public view returns (
        int,
        int,
        BalanceState memory,
        PortfolioState memory,
        MarketParameters[] memory
    ) {
        int incentivePaid = factors.liquidateLocalLiquidityTokens(
            blockTime,
            localBalanceContext,
            portfolioState
        );

        return (
            incentivePaid,
            factors.localAssetRequired,
            localBalanceContext,
            portfolioState,
            factors.localMarketStates
        );
    }

    function liquidateCollateral(
        LiquidationFactors memory factors,
        BalanceState memory collateralBalanceContext,
        PortfolioState memory portfolioState,
        int maxLiquidateAmount,
        uint blockTime
    ) public view returns (
        int,
        BalanceState memory,
        PortfolioState memory
    ) {
        (int localToPurchase, /* int perpetualTokensToTransfer */) = Liquidation.liquidateCollateral(
            factors,
            collateralBalanceContext,
            portfolioState,
            maxLiquidateAmount,
            blockTime
        );

        return (
            localToPurchase,
            collateralBalanceContext,
            portfolioState
        );
    }

    function liquidatefCash(
        LiquidationFactors memory factors,
        uint[] memory fCashAssetMaturities,
        int maxLiquidateAmount,
        PortfolioState memory portfolioState
    ) public pure returns (int) {
        return factors.liquidatefCash(
            fCashAssetMaturities,
            maxLiquidateAmount,
            portfolioState
        );
    }
}