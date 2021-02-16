// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/FreeCollateral.sol";
import "../storage/StorageLayoutV1.sol";

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
        PortfolioState memory portfolioState,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory marketStates,
        uint blockTime
    ) public view returns (PortfolioAsset[] memory, int[] memory) {
        return FreeCollateral.setupFreeCollateral(
            portfolioState,
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