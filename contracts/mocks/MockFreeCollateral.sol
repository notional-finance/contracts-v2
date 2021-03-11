// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/FreeCollateral.sol";
import "../storage/StorageLayoutV1.sol";

contract MockFreeCollateral is StorageLayoutV1 {

    function setupFreeCollateralStateful(
        PortfolioState memory portfolioState,
        uint blockTime
    ) public returns (
        PortfolioAsset[] memory,
        int[] memory,
        CashGroupParameters[] memory,
        MarketParameters[][] memory
    ) {
        return FreeCollateral.setupFreeCollateralStateful(
            portfolioState,
            blockTime
        );
    }

    function getFreeCollateral(
        BalanceState[] memory balanceState,
        CashGroupParameters[] memory cashGroups,
        int[] memory netPortfolioValue,
        uint blockTime
    ) public returns (int) {
        return FreeCollateral.getFreeCollateralStateful(
            balanceState,
            cashGroups,
            netPortfolioValue,
            blockTime
        );
    }

    function getAllCashGroups(
        PortfolioAsset[] memory assets
    ) public returns (CashGroupParameters[] memory, MarketParameters[][] memory) {
        return FreeCollateral.getAllCashGroupsStateful(assets);
    }

}