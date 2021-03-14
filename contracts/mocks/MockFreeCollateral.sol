// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../actions/libraries/FreeCollateralExternal.sol";
import "../storage/PortfolioHandler.sol";
import "./MockAssetHandler.sol";

contract MockFreeCollateral is MockAssetHandler {
    using PortfolioHandler for PortfolioState;

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
        PortfolioState memory portfolioState = PortfolioHandler.buildPortfolioState(account, 0);
        portfolioState.newAssets = assets;
        portfolioState.storeAssets(assetArrayMapping[account]);
    }

    function setBalance(
        address account,
        uint currencyId,
        int cashBalance,
        int perpTokenBalance
    ) external {
        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));

        bytes32 data = (
            (bytes32(uint(perpTokenBalance))) |
            (bytes32(0) << 96) |
            (bytes32(cashBalance) << 128)
        );

        assembly { sstore(slot, data) }
    }

    function getFreeCollateralView(
        address account
    ) external view returns (int) {
        return FreeCollateralExternal.getFreeCollateralView(account);
    }

    function checkFreeCollateralAndRevert(
        address account
    ) external {
        FreeCollateralExternal.checkFreeCollateralAndRevert(account, true);
    }

}