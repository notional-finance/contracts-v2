// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./Asset.sol";
import "./CashGroup.sol";
import "./ExchangeRate.sol";
import "../math/SafeInt256.sol";
import "../storage/BalanceHandler.sol";
import "../storage/PortfolioHandler.sol";

library FreeCollateral {
    using SafeInt256 for int;
    using PortfolioHandler for PortfolioState;
    using BalanceHandler for BalanceState;
    using ExchangeRate for ETHRate;
    using AssetRate for AssetRateParameters;

    /**
     * @notice Returns true if the account passes free collateral. Assumes that any trading will result in
     * a balance context object being created.
     */
    function doesAccountPassFreeCollateral(
        address account,
        AccountStorage memory accountContext,
        PortfolioState memory portfolioState,
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates,
        uint blockTime
    ) internal view returns (bool) {
        if (!accountContext.hasDebt
            && portfolioState.storedAssets.length == 0
            && portfolioState.newAssets.length == 0) {
            // Fetch the portfolio state if it does not exist and we need to check free collateral.
            // TODO: need to get this storage pointer somehow
            // portfolioState = PortfolioHandler.buildPortfolioState(assetArrayMapping[account], 0);
        }

        (/* */, int[] memory netPortfolioValue) = setupFreeCollateral(
            account,
            accountContext,
            portfolioState,
            balanceState,
            cashGroups,
            marketStates,
            blockTime
        );

        // TODO: all balances must be finalized before this gets called to account for transfers
        // and potential transfer fees
        int ethDenominatedFC = getFreeCollateral(balanceState, cashGroups, netPortfolioValue);

        return ethDenominatedFC >= 0;
    }


    function setupFreeCollateral(
        address account,
        AccountStorage memory accountContext,
        PortfolioState memory portfolioState,
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates,
        uint blockTime
    ) internal view returns (PortfolioAsset[] memory, int[] memory) {
        // Get remaining balances that have not changed, all balances is an ordered array of the
        // currency ids. This is the same ordering that portfolioState.storedAssets and newAssets
        // are also stored in.
        balanceState = BalanceHandler.getRemainingActiveBalances(
            account,
            // TODO: this does not contain assets that do not have cash balances, ensure that
            // trading will result in a balance entering the context
            accountContext,
            balanceState
        );

        // TODO: ensure sorting, it may have changed after finalizing...does that need to be the case?
        portfolioState.calculateSortedIndex();
        PortfolioAsset[] memory allActiveAssets = portfolioState.getMergedArray();
        // Ensure that cash groups and markets are up to date
        (cashGroups, marketStates) = getAllCashGroups(allActiveAssets, cashGroups, marketStates);
        // TODO: this changes references in memory, must ensure that we optmisitically write
        // changes to storage before we execute this method
        int[] memory netPortfolioValue = Asset.getRiskAdjustedPortfolioValue(
            allActiveAssets,
            cashGroups,
            marketStates,
            blockTime
        );

        return (allActiveAssets, netPortfolioValue);
    }

    /**
     * @notice Aggregates the portfolio value with cash balances to get the net free collateral value.
     */
    function getFreeCollateral(
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        int[] memory netPortfolioValue
    ) internal view returns (int) {
        uint groupIndex;
        int netETHValue;

        for (uint i; i < balanceState.length; i++) {
            // Cash balances are denominated in underlying
            int perpetualTokenValue;
            int netLocalAssetValue = balanceState[i].storedCashBalance;
            if (balanceState[i].storedPerpetualTokenBalance > 0) {
                perpetualTokenValue = balanceState[i].getPerpetualTokenAssetValue();
                netLocalAssetValue = netLocalAssetValue.add(perpetualTokenValue);
            }

            AssetRateParameters memory assetRate;
            if (cashGroups[groupIndex].currencyId == balanceState[i].currencyId) {
                netLocalAssetValue = netLocalAssetValue.add(netPortfolioValue[groupIndex]);
                groupIndex += 1;
            } else {
                // TODO: there is a stateful and non-stateful version of this function
                assetRate = AssetRate.buildAssetRate(balanceState[i].currencyId);
            }
            // TODO: short circuit this if the currency is ETH
            ETHRate memory ethRate = ExchangeRate.buildExchangeRate(balanceState[i].currencyId);
            int ethValue = ethRate.convertToETH(
                assetRate.convertInternalToUnderlying(netLocalAssetValue)
            );

            netETHValue = netETHValue.add(ethValue);
        }

        return netETHValue;
    }

    /**
     * @notice Ensures that all cash groups in a set of active assets are in the list of cash groups.
     * Cash groups can be in the active assets but not loaded yet if they have been previously traded.
     * 
     * Cash groups can also be in the array but NOT in the active assets list if they have been net off
     * as a result of a trade or settled.
     */
    function getAllCashGroups(
        PortfolioAsset[] memory assets,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates
    ) internal view returns (CashGroupParameters[] memory, MarketParameters[][] memory) {
        uint missingGroups;
        uint groupIndex;

        // Count the total number of groups that we're missing, you can't rely on total group count
        // because it's possible that there is one additional and one missing and they will net out
        for (uint i; i < assets.length; i++) {
            while (assets[i].currencyId > cashGroups[groupIndex].currencyId) {
                // Since assets are sorted we can safely advance the group index in this case
                groupIndex += 1;
            }
            if (assets[i].currencyId == cashGroups[groupIndex].currencyId) continue;
            if (assets[i].currencyId < cashGroups[groupIndex].currencyId) missingGroups += 1;
        }

        if (missingGroups == 0) return (cashGroups, marketStates);

        // If missing groups ensure that they get provisioned in
        CashGroupParameters[] memory newCashGroups = new CashGroupParameters[](cashGroups.length + missingGroups);
        MarketParameters[][] memory newMarketStates = new MarketParameters[][](cashGroups.length + missingGroups);
        groupIndex = 0;
        uint newGroupIndex = 0;
        for (uint i; i < assets.length; i++) {
            uint currentCurrencyId = assets[i].currencyId;
            // Reached the final cash group
            if (newGroupIndex == newCashGroups.length) break;
            // No need to update
            if (currentCurrencyId == newCashGroups[newGroupIndex].currencyId) continue;
            // Cash group already in the previous index
            if (currentCurrencyId == cashGroups[groupIndex].currencyId) {
                newCashGroups[newGroupIndex] = cashGroups[groupIndex];
                newMarketStates[newGroupIndex] = marketStates[groupIndex];
                newGroupIndex += 1;
                groupIndex += 1;
            } else {
                // This is a missing cash group
                (
                    newCashGroups[newGroupIndex],
                    newMarketStates[newGroupIndex]
                ) = CashGroup.buildCashGroup(assets[i].currencyId);
                newGroupIndex += 1;
            }

            while (currentCurrencyId > cashGroups[groupIndex].currencyId) {
                // In this case the current cash group is behind the assets so we catch it up
                newCashGroups[newGroupIndex] = cashGroups[groupIndex];
                newMarketStates[newGroupIndex] = marketStates[groupIndex];
                newGroupIndex += 1;
                groupIndex += 1;
            }
        }

        return (newCashGroups, newMarketStates);
    }

    /**
     * @notice Checks if an account that does not have debt is incurring debt.
     */
    function shouldCheckFreeCollateral(
        AccountStorage memory accountContext,
        BalanceState[] memory balanceState,
        PortfolioState memory portfolioState
    ) internal pure returns (bool) {
        if (!accountContext.hasDebt) {
            // If the account does not previously have debt we want to check that the
            // changes happening here do not put it into debt.
            for (uint i; i < balanceState.length; i++) {
                // Unclear how this can occur, cash balances can only
                // be negative if debts have settled which means hasDebt should
                // be set to true...although maybe it does not hurt to check
                int finalCash = balanceState[i].storedCashBalance.add(balanceState[i].netCashChange);
                if (finalCash < 0) return true;
            }

            // Check new and existing portfolio assets for debt
            for (uint i; i < portfolioState.storedAssets.length; i++) {
                if (portfolioState.storedAssets[i].storageState == AssetStorageState.Delete) continue;
                if (portfolioState.storedAssets[i].notional < 0) return true;
            }

            for (uint i; i < portfolioState.newAssets.length; i++) {
                if (portfolioState.newAssets[i].notional < 0) return true;
            }

            // At this point we know that the account has not incurred debt so we
            // can quit.
            return false;
        }

        return true;
    }
}

contract MockFreeCollateral is StorageLayoutV1 {

    function doesAccountPassFreeCollateral(
        address account,
        AccountStorage memory accountContext,
        PortfolioState memory portfolioState,
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates,
        uint blockTime
    ) public view returns (bool) {
        return FreeCollateral.doesAccountPassFreeCollateral(
            account,
            accountContext,
            portfolioState,
            balanceState,
            cashGroups,
            marketStates,
            blockTime
        );
    }

    function setupFreeCollateral(
        address account,
        AccountStorage memory accountContext,
        PortfolioState memory portfolioState,
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates,
        uint blockTime
    ) public view returns (PortfolioAsset[] memory, int[] memory) {
        return FreeCollateral.setupFreeCollateral(
            account,
            accountContext,
            portfolioState,
            balanceState,
            cashGroups,
            marketStates,
            blockTime
        );
    }

    function getFreeCollateral(
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        int[] memory netPortfolioValue
    ) public view returns (int) {
        return FreeCollateral.getFreeCollateral(
            balanceState,
            cashGroups,
            netPortfolioValue
        );
    }

    function getAllCashGroups(
        PortfolioAsset[] memory assets,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates
    ) public view returns (CashGroupParameters[] memory, MarketParameters[][] memory) {
        return FreeCollateral.getAllCashGroups(
            assets,
            cashGroups,
            marketStates
        );
    }

    function shouldCheckFreeCollateral(
        AccountStorage memory accountContext,
        BalanceState[] memory balanceState,
        PortfolioState memory portfolioState
    ) public pure returns (bool) {
        return FreeCollateral.shouldCheckFreeCollateral(
            accountContext,
            balanceState,
            portfolioState
        );
    }
}