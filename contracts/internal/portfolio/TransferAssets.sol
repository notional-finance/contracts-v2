// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    PortfolioState,
    PortfolioAsset,
    AccountContext
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {PortfolioHandler} from "./PortfolioHandler.sol";
import {BitmapAssetsHandler} from "./BitmapAssetsHandler.sol";
import {AccountContextHandler} from "../AccountContextHandler.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

/// @notice Helper library for transferring assets from one portfolio to another
library TransferAssets {
    using AccountContextHandler for AccountContext;
    using PortfolioHandler for PortfolioState;
    using SafeInt256 for int256;

    /// @dev Used to flip the sign of assets to decrement the `from` account that is sending assets
    function invertNotionalAmountsInPlace(PortfolioAsset[] memory assets) internal pure {
        for (uint256 i; i < assets.length; i++) {
            assets[i].notional = assets[i].notional.neg();
        }
    }

    /// @dev Useful method for hiding the logic of updating an account. WARNING: the account
    /// context returned from this method may not be the same memory location as the account
    /// context provided if the account is settled.
    function placeAssetsInAccount(
        address account,
        AccountContext memory accountContext,
        PortfolioAsset[] memory assets
    ) internal returns (AccountContext memory) {
        // If an account has assets that require settlement then placing assets inside it
        // may cause issues.
        require(!accountContext.mustSettleAssets(), "Account must settle");

        if (accountContext.isBitmapEnabled()) {
            // Adds fCash assets into the account and finalized storage
            BitmapAssetsHandler.addMultipleifCashAssets(account, accountContext, assets);
        } else {
            PortfolioState memory portfolioState = PortfolioHandler.buildPortfolioState(
                account,
                accountContext.assetArrayLength,
                assets.length
            );
            // This will add assets in memory
            portfolioState.addMultipleAssets(assets);
            // This will store assets and update the account context in memory
            accountContext.storeAssetsAndUpdateContext(account, portfolioState);
        }

        return accountContext;
    }
}
