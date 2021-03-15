// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/PortfolioHandler.sol";
import "../storage/AccountContextHandler.sol";
import "../common/Liquidation.sol";
import "../storage/StorageLayoutV1.sol";
import "./BaseMockLiquidation.sol";

contract MockLiquidateTokens is BaseMockLiquidation {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;
    using Liquidation for LiquidationFactors;
    using Market for MarketParameters;

    function calculateLiquidationFactors(
        address account,
        uint blockTime,
        uint localCurrencyId,
        uint collateralCurrencyId
    ) public returns (LiquidationFactors memory) {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState[] memory balanceState = accountContext.getAllBalances(account);
        PortfolioAsset[] memory portfolio = PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength);

        return Liquidation.calculateLiquidationFactors(
            portfolio,
            balanceState,
            blockTime,
            localCurrencyId,
            collateralCurrencyId
        );
    }

    function liquidateLocalLiquidityTokens(
        address account,
        LiquidationFactors memory factors,
        uint blockTime
    ) public view returns (int, int, int, PortfolioState memory, MarketParameters[] memory) {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory portfolioState = PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);
        (int incentivePaid, int netCashChange) = factors.liquidateLocalLiquidityTokens(portfolioState, blockTime);

        return (
            incentivePaid,
            factors.localAssetRequired,
            netCashChange,
            portfolioState,
            factors.localMarketStates
        );
    }
}

contract MockLiquidateCollateral is BaseMockLiquidation {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;
    using Liquidation for LiquidationFactors;
    using Market for MarketParameters;

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
}

    // function liquidatefCash(
    //     LiquidationFactors memory factors,
    //     uint[] memory fCashAssetMaturities,
    //     int maxLiquidateAmount,
    //     PortfolioState memory portfolioState
    // ) public pure returns (int) {
    //     return factors.liquidatefCash(
    //         fCashAssetMaturities,
    //         maxLiquidateAmount,
    //         portfolioState
    //     );
    // }