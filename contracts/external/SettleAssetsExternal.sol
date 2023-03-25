// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    AccountContext,
    PrimeRate,
    PortfolioAsset,
    PortfolioState,
    SettleAmount
} from "../global/Types.sol";
import {Constants} from "../global/Constants.sol";
import {SafeInt256} from "../math/SafeInt256.sol";

import {Emitter} from "../internal/Emitter.sol";
import {AccountContextHandler} from "../internal/AccountContextHandler.sol";
import {PortfolioHandler} from "../internal/portfolio/PortfolioHandler.sol";
import {TransferAssets} from "../internal/portfolio/TransferAssets.sol";
import {BalanceHandler} from "../internal/balances/BalanceHandler.sol";
import {SettlePortfolioAssets} from "../internal/settlement/SettlePortfolioAssets.sol";
import {SettleBitmapAssets} from "../internal/settlement/SettleBitmapAssets.sol";
import {PrimeRateLib} from "../internal/pCash/PrimeRateLib.sol";

/// @notice External library for settling assets and portfolio management
library SettleAssetsExternal {
    using SafeInt256 for int256;
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountContext;

    event AccountSettled(address indexed account);

    /// @notice Settles an account, returns the new account context object after settlement.
    /// @dev The memory location of the account context object is not the same as the one returned.
    function settleAccount(
        address account,
        AccountContext memory accountContext
    ) external returns (AccountContext memory) {
        // Defensive check to ensure that this is a valid settlement
        require(accountContext.mustSettleAssets());
        return _settleAccount(account, accountContext);
    }

    /// @notice Stores a portfolio state and returns the updated context
    /// @dev Called from BatchAction
    function storeAssetsInPortfolioState(
        address account,
        AccountContext memory accountContext,
        PortfolioState memory state
    ) external returns (AccountContext memory) {
        accountContext.storeAssetsAndUpdateContext(account, state);
        // NOTE: this account context returned is in a different memory location than
        // the one passed in.
        return accountContext;
    }

    function _settleAccount(
        address account,
        AccountContext memory accountContext
    ) private returns (AccountContext memory) {
        SettleAmount[] memory settleAmounts;
        PortfolioState memory portfolioState;

        if (accountContext.isBitmapEnabled()) {
            PrimeRate memory presentPrimeRate = PrimeRateLib
                .buildPrimeRateStateful(accountContext.bitmapCurrencyId);

            (int256 positiveSettledCash, int256 negativeSettledCash, uint256 blockTimeUTC0) =
                SettleBitmapAssets.settleBitmappedCashGroup(
                    account,
                    accountContext.bitmapCurrencyId,
                    accountContext.nextSettleTime,
                    block.timestamp,
                    presentPrimeRate
                );
            require(blockTimeUTC0 < type(uint40).max); // dev: block time utc0 overflow
            accountContext.nextSettleTime = uint40(blockTimeUTC0);

            settleAmounts = new SettleAmount[](1);
            settleAmounts[0] = SettleAmount({
                currencyId: accountContext.bitmapCurrencyId,
                positiveSettledCash: positiveSettledCash,
                negativeSettledCash: negativeSettledCash,
                presentPrimeRate: presentPrimeRate
            });
        } else {
            portfolioState = PortfolioHandler.buildPortfolioState(
                account, accountContext.assetArrayLength, 0
            );
            settleAmounts = SettlePortfolioAssets.settlePortfolio(account, portfolioState, block.timestamp);
            accountContext.storeAssetsAndUpdateContextForSettlement(
                account, portfolioState
            );
        }

        BalanceHandler.finalizeSettleAmounts(account, accountContext, settleAmounts);

        emit AccountSettled(account);

        return accountContext;
    }
}
