// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/PortfolioHandler.sol";
import "../storage/AccountContextHandler.sol";
import "../common/Liquidation.sol";
import "../storage/StorageLayoutV1.sol";
import "./MockAssetHandler.sol";

contract MockLiquidation is StorageLayoutV1 {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountStorage;
    using Liquidation for LiquidationFactors;
    using Market for MarketParameters;

    function setAssetRateMapping(
        uint id,
        AssetRateStorage calldata rs
    ) external {
        assetToUnderlyingRateMapping[id] = rs;
    }

    function setCashGroup(
        uint id,
        CashGroupParameterStorage calldata cg
    ) external {
        CashGroup.setCashGroupStorage(id, cg);
    }

    function buildCashGroupView(
        uint currencyId
    ) public view returns (
        CashGroupParameters memory,
        MarketParameters[] memory
    ) {
        return CashGroup.buildCashGroupView(currencyId);
    }

    function setMarketStorage(
        uint currencyId,
        uint settlementDate,
        MarketParameters memory market
    ) public {
        market.storageSlot = Market.getSlot(currencyId, market.maturity, settlementDate);
        // ensure that state gets set
        market.storageState = 0xFF;
        market.setMarketStorage();
   }

    function setETHRateMapping(
        uint id,
        ETHRateStorage calldata rs
    ) external {
        underlyingToETHRateMapping[id] = rs;
    }

    function setPortfolio(
        address account,
        PortfolioAsset[] memory assets
    ) external {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        PortfolioState memory portfolioState = PortfolioHandler.buildPortfolioState(account, accountContext.assetArrayLength, 0);
        portfolioState.newAssets = assets;
        portfolioState.storeAssets(account, accountContext);

        // TODO: fix this hack
        accountContext.setActiveCurrency(assets[0].currencyId, true);
        accountContext.setAccountContext(account);
    }

    function setBalance(
        address account,
        uint currencyId,
        int cashBalance,
        int perpTokenBalance
    ) external {
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.setActiveCurrency(currencyId, true);
        accountContext.setAccountContext(account);

        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));

        bytes32 data = (
            (bytes32(uint(perpTokenBalance))) |
            (bytes32(0) << 96) |
            (bytes32(cashBalance) << 128)
        );

        assembly { sstore(slot, data) }
    }

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

    // function liquidateCollateral(
    //     LiquidationFactors memory factors,
    //     BalanceState memory collateralBalanceContext,
    //     PortfolioState memory portfolioState,
    //     int maxLiquidateAmount,
    //     uint blockTime
    // ) public view returns (
    //     int,
    //     BalanceState memory,
    //     PortfolioState memory
    // ) {
    //     (int localToPurchase, /* int perpetualTokensToTransfer */) = Liquidation.liquidateCollateral(
    //         factors,
    //         collateralBalanceContext,
    //         portfolioState,
    //         maxLiquidateAmount,
    //         blockTime
    //     );

    //     return (
    //         localToPurchase,
    //         collateralBalanceContext,
    //         portfolioState
    //     );
    // }

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
}