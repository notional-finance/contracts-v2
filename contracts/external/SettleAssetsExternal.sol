// SPDX-License-Identifier: BSUL-1.1
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

    /// @notice Transfers a set of assets from one account to the other.
    /// @dev This method does not check free collateral, even though it may be required. The calling
    /// method is responsible for ensuring that free collateral is checked.
    /// @dev Called from LiquidatefCash#_transferAssets, ERC1155Action#_transfer
    function transferAssets(
        address fromAccount,
        address toAccount,
        AccountContext memory fromContextBefore,
        AccountContext memory toContextBefore,
        PortfolioAsset[] memory assets
    ) external returns (
        AccountContext memory fromContextAfter,
        AccountContext memory toContextAfter
    ) {
        // Emit events before notional amounts are inverted in place
        Emitter.emitBatchTransferfCash(fromAccount, toAccount, assets);

        toContextAfter = _settleAndPlaceAssets(toAccount, toContextBefore, assets);

        // Will flip the sign of notional in the assets array in memory
        TransferAssets.invertNotionalAmountsInPlace(assets);

        fromContextAfter = _settleAndPlaceAssets(fromAccount, fromContextBefore, assets);
    }

    /// @notice Places the assets in the account whether it is holding a bitmap or
    /// normal array type portfolio. Will revert if account has not been settled.
    /// @dev Called from AccountAction#nTokenRedeem
    function placeAssetsInAccount(
        address account,
        address fromAccount,
        AccountContext memory accountContext,
        PortfolioAsset[] memory assets
    ) external returns (AccountContext memory) {
        Emitter.emitBatchTransferfCash(fromAccount, account, assets);
        return TransferAssets.placeAssetsInAccount(account, accountContext, assets);
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

    /// @notice Transfers cash from a vault account to a vault liquidator
    /// @dev Called from VaultLiquidationAction#liquidateVaultCashBalance
    /// @return true if free collateral must be checked on the liquidator
    function transferCashToVaultLiquidator(
        address liquidator,
        address vault,
        address account,
        uint16 currencyId,
        uint256 maturity,
        int256 fCashToVault,
        int256 cashToLiquidator
    ) external returns (bool) {
        AccountContext memory context = AccountContextHandler.getAccountContext(liquidator);
        PortfolioAsset[] memory assets = new PortfolioAsset[](1);
        assets[0].currencyId = currencyId;
        assets[0].maturity = maturity;
        assets[0].assetType = Constants.FCASH_ASSET_TYPE;
        assets[0].notional = fCashToVault.neg();

        context = _settleAndPlaceAssets(liquidator, context, assets);

        BalanceHandler.setBalanceStorageForfCashLiquidation(
            liquidator,
            context,
            currencyId,
            cashToLiquidator,
            PrimeRateLib.buildPrimeRateStateful(currencyId)
        );

        context.setAccountContext(liquidator);

        // The vault is transferring prime cash to the liquidator in exchange for cash.
        Emitter.emitTransferPrimeCash(vault, liquidator, currencyId, cashToLiquidator);
        // fCashToVault is positive here. The liquidator will transfer fCash to the vault
        // and the vault will burn it to repay negative fCash debt.
        Emitter.emitTransferfCash(liquidator, vault, currencyId, maturity, fCashToVault);
        // The account will burn its debt and vault cash
        Emitter.emitVaultAccountCashBurn(
            account, vault, currencyId, maturity, fCashToVault, cashToLiquidator
        );
        
        // A free collateral check is required here because the liquidator is receiving cash
        // and transferring out fCash. It's possible that the collateral value of the fCash
        // is larger than the cash transferred in. Cannot check debt in this library since it
        // creates a circular dependency with FreeCollateralExternal. Done in VaultLiquidationAction
        return context.hasDebt != 0x00;
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

    function _settleAndPlaceAssets(
        address account,
        AccountContext memory context,
        PortfolioAsset[] memory assets
    ) private returns (AccountContext memory) {
        if (context.mustSettleAssets()) {
            context = _settleAccount(account, context);
        }

        return TransferAssets.placeAssetsInAccount(account, context, assets);
    }
}
