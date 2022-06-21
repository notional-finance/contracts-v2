// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {
    VaultAccount,
    VaultAccountStorage,
    TradeActionType,
    VaultSettledAssetsStorage
} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {TradingAction} from "../../external/actions/TradingAction.sol";
import {DateTime} from "../markets/DateTime.sol";

import {CashGroup, CashGroupParameters, Market, MarketParameters} from "../markets/CashGroup.sol";
import {AssetRate, AssetRateParameters} from "../markets/AssetRate.sol";
import {TokenType, Token, TokenHandler} from "../balances/TokenHandler.sol";

import {VaultConfig, VaultConfiguration} from "./VaultConfiguration.sol";
import {VaultStateLib, VaultState} from "./VaultState.sol";
import {IStrategyVault} from "../../../interfaces/notional/IStrategyVault.sol";

library VaultAccountLib {
    using VaultConfiguration for VaultConfig;
    using VaultStateLib for VaultState;
    using AssetRate for AssetRateParameters;
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;
    using TokenHandler for Token;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    /// @notice Returns a single account's vault position
    function getVaultAccount(
        address account, VaultConfig memory vaultConfig
    ) internal view returns (VaultAccount memory vaultAccount) {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage.getVaultAccount();
        VaultAccountStorage storage s = store[account][vaultConfig.vault];

        // fCash is negative on the stack
        vaultAccount.fCash = -int256(uint256(s.fCash));
        vaultAccount.maturity = s.maturity;
        vaultAccount.vaultShares = s.vaultShares;
        vaultAccount.account = account;
        vaultAccount.tempCashBalance = 0;
    }

    /// @notice Sets a single account's vault position in storage
    function setVaultAccount(VaultAccount memory vaultAccount, VaultConfig memory vaultConfig) internal {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage
            .getVaultAccount();
        VaultAccountStorage storage s = store[vaultAccount.account][vaultConfig.vault];

        // The temporary cash balance must be cleared to zero by the end of the transaction
        require(vaultAccount.tempCashBalance == 0); // dev: cash balance not cleared
        // An account must maintain a minimum borrow size in order to enter the vault. If the account
        // wants to exit under the minimum borrow size it must fully exit so that we do not have dust
        // accounts that become insolvent.
        require(vaultAccount.fCash == 0 || vaultConfig.minAccountBorrowSize <= vaultAccount.fCash.neg(), "Min Borrow");

        s.fCash = vaultAccount.fCash.neg().toUint().toUint80();
        s.vaultShares = vaultAccount.vaultShares.toUint80();
        s.maturity = vaultAccount.maturity.toUint32();
    }

    /// @notice Updates an account's fCash position and the current vault state at the same time. Also updates
    /// and checks the total borrow capacity
    /// @param vaultAccount vault account
    /// @param vaultConfig vault configuration
    /// @param vaultState vault state matching the maturity
    /// @param netfCash fCash change to the account, (borrowing < 0, lending > 0)
    /// @param netAssetCash amount of asset cash to charge or credit to the account, must be the oppositely
    /// signed compared to the netfCash sign
    function updateAccountfCash(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        int256 netfCash,
        int256 netAssetCash
    ) internal {
        require(vaultState.maturity == vaultAccount.maturity);
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(netAssetCash);

        // Update fCash state on the account and the vault
        vaultAccount.fCash = vaultAccount.fCash.add(netfCash);
        require(vaultAccount.fCash <= 0);
        vaultState.totalfCash = vaultState.totalfCash.add(netfCash);
        require(vaultState.totalfCash <= 0);

        // Updates the total borrow capacity
        VaultConfiguration.updateUsedBorrowCapacity(vaultConfig.vault, vaultConfig.borrowCurrencyId, netfCash);
    }


    /// @notice Enters into a vault position, borrowing from Notional if required.
    /// @param vaultAccount vault account entering the position
    /// @param vaultConfig vault configuration
    /// @param maturity maturity to enter into
    /// @param fCashToBorrow a positive amount of fCash to borrow, will be converted to a negative
    /// amount inside the method
    /// @param maxBorrowRate the maximum annualized interest rate to borrow at, a zero signifies no
    /// slippage limit applied
    /// @param vaultData arbitrary data to be passed to the vault
    /// @param strategyTokenDeposit some amount of strategy tokens from a previous maturity that will
    /// be carried over into the current maturity
    /// @param additionalUnderlyingExternal some amount of underlying tokens that have been deposited
    /// during enterVault as additional collateral.
    function borrowAndEnterVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 maturity,
        uint256 fCashToBorrow,
        uint32 maxBorrowRate,
        bytes calldata vaultData,
        uint256 strategyTokenDeposit,
        uint256 additionalUnderlyingExternal
    ) internal {
        // The vault account can only be increasing their borrow position or not have one set. If they
        // are increasing their position they must be borrowing from the same maturity.
        require(vaultAccount.maturity == maturity || vaultAccount.fCash == 0);
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, maturity);

        // Borrows fCash and puts the cash balance into the vault account's temporary cash balance
        if (fCashToBorrow > 0) {
            _borrowIntoVault(
                vaultAccount,
                vaultConfig,
                vaultState,
                maturity,
                fCashToBorrow.toInt().neg(),
                maxBorrowRate
            );
        }

        // Sets the maturity on the vault account, deposits tokens into the vault, and updates the vault state 
        vaultState.enterMaturity(
            vaultAccount, vaultConfig, strategyTokenDeposit, additionalUnderlyingExternal, vaultData
        );

        // Set the vault state and account in storage and check the vault's collateral ratio
        vaultState.setVaultState(vaultConfig.vault);
        setVaultAccount(vaultAccount, vaultConfig);

        // If the account is not using any leverage (fCashToBorrow == 0) we don't check the collateral ratio, no matter
        // what the amount is the collateral ratio will increase. This is useful for accounts that want to quickly and cheaply
        // increase their collateral ratio without paying down debts.
        if (fCashToBorrow > 0) {
            vaultConfig.checkCollateralRatio(vaultState, vaultAccount);
        }
    }

    ///  @notice Borrows fCash to enter a vault and pays fees
    ///  @dev Updates vault fCash in storage, updates vaultAccount in memory
    ///  @param vaultAccount the account's position in the vault
    ///  @param vaultConfig configuration for the given vault
    ///  @param maturity the maturity to enter for the vault
    ///  @param fCash amount of fCash to borrow from the market, must be negative
    ///  @param maxBorrowRate maximum annualized rate to pay for the borrow
    function _borrowIntoVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 maturity,
        int256 fCash,
        uint32 maxBorrowRate
    ) private {
        require(fCash < 0); // dev: fcash must be negative

        int256 assetCashBorrowed  = executeTrade(
            vaultConfig.borrowCurrencyId,
            maturity,
            fCash,
            maxBorrowRate,
            vaultConfig.maxBorrowMarketIndex,
            block.timestamp
        );
        require(assetCashBorrowed > 0, "Borrow failed");

        updateAccountfCash(vaultAccount, vaultConfig, vaultState, fCash, assetCashBorrowed);

        // Ensure that we are above the minimum borrow size. Accounts smaller than this are not profitable
        // to unwind if we need to liquidate.
        require(vaultConfig.minAccountBorrowSize <= vaultAccount.fCash.neg(), "Min Borrow");

        uint256 timeToMaturity = maturity.sub(block.timestamp);
        // Will reduce the tempCashBalance based on the assessed vault fee
        vaultConfig.assessVaultFees(vaultAccount, fCash, timeToMaturity);
    }

    /// @notice Allows an account to exit a vault term prematurely by lending fCash.
    /// @param vaultAccount the account's position in the vault
    /// @param vaultConfig configuration for the given vault
    /// @param fCash amount of fCash to lend from the market, must be positive and cannot
    /// lend more than the account's debt
    /// @param minLendRate minimum rate to lend at
    /// @param blockTime current block time
    function lendToExitVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        int256 fCash,
        uint32 minLendRate,
        uint256 blockTime
    ) internal {
        // Don't allow the vault to lend to positive fCash
        require(vaultAccount.fCash.add(fCash) <= 0); // dev: cannot lend to positive fCash
        
        // Check that the account is in an active vault
        require(blockTime < vaultAccount.maturity);
        
        // Returns the cost in asset cash terms as a negative value to lend an offsetting fCash position
        // so that the account can exit.
        int256 assetCashCostToLend  = executeTrade(
            vaultConfig.borrowCurrencyId,
            vaultAccount.maturity,
            fCash,
            minLendRate,
            vaultConfig.maxBorrowMarketIndex,
            blockTime
        );

        if (assetCashCostToLend == 0) {
            // In this case, the lending has failed due to a lack of liquidity or negative interest rates. In this
            // case just just net off the the asset cash balance and the account will forgo any money market interest
            // accrued between now and maturity.
            
            // If this scenario were to occur, it is most likely that interest rates are near zero suggesting that
            // money market interest rates are also near zero (therefore the account is really not giving up much
            // by forgoing money market interest).
            // NOTE: fCash is positive here so assetCashToLend will be negative
            assetCashCostToLend = vaultConfig.assetRate.convertFromUnderlying(fCash).neg();
        }
        require(assetCashCostToLend <= 0);

        updateAccountfCash(vaultAccount, vaultConfig, vaultState, fCash, assetCashCostToLend);
        // NOTE: vault account and vault state are not set into storage in this method.
    }

    /// @notice Calculates the amount a liquidator can deposit in asset cash terms to deleverage an account.
    /// @param vaultAccount the vault account to deleverage
    /// @param vaultConfig the vault configuration
    /// @param vaultShareValue value of the vault account's vault shares
    /// @return maxLiquidatorDepositAssetCash the maximum a liquidator can deposit in asset cash internal denomination
    /// @return mustLiquidateFullAmount if true, the liquidator must deposit the full amount to bring an account
    /// to zero fCash (below the minBorrowAmount)
    function calculateDeleverageAmount(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        int256 vaultShareValue
    ) internal pure returns (int256 maxLiquidatorDepositAssetCash, bool mustLiquidateFullAmount) {
        // In the base case, the liquidator can deleverage an account up to maxDeleverageCollateralRatio, this
        // assures that a liquidator cannot over-purchase assets on an account.
        int256 maxCollateralRatioPlusOne = vaultConfig.maxDeleverageCollateralRatio.add(Constants.RATE_PRECISION);

        // All calculations in this method are done in asset cash denomination
        int256 debtOutstanding = vaultConfig.assetRate.convertFromUnderlying(vaultAccount.fCash.neg());

        // The post liquidation collateral ratio is calculated as:
        //                          (shareValue - (debtOutstanding - deposit * (1 - liquidationRate)))
        //   postLiquidationRatio = ----------------------------------------------------------------
        //                                          (debtOutstanding - deposit)
        //
        //   if we rearrange terms to put the deposit on one side we get:
        //
        //              (postLiquidationRatio + 1) * debtOutstanding - shareValue
        //   deposit =  ---------------------------------------------------------- 
        //                  (postLiquidationRatio + 1) - liquidationRate

        maxLiquidatorDepositAssetCash = (
            debtOutstanding.mulInRatePrecision(maxCollateralRatioPlusOne).sub(vaultShareValue)
        // Both denominators are in 1e9 precision
        ).divInRatePrecision(maxCollateralRatioPlusOne.sub(vaultConfig.liquidationRate));

        // If an account's (debtOutstanding - maxLiquidatorDeposit) < minAccountBorrowSize it may not be profitable
        // to liquidate a second time due to gas costs. If this occurs the liquidator must liquidate the account such
        // that it has no fCash debt.
        int256 postLiquidationDebtRemaining = debtOutstanding.sub(maxLiquidatorDepositAssetCash);
        int256 minAccountBorrowSizeAssetCash = vaultConfig.assetRate.convertFromUnderlying(
            vaultConfig.minAccountBorrowSize
        );

        // All terms here are in asset cash
        if (postLiquidationDebtRemaining < minAccountBorrowSizeAssetCash) {
            // If the postLiquidationDebtRemaining is negative (over liquidation) or below the minAccountBorrowSize set the
            // max deposit amount to set the fCash debt to zero.
            maxLiquidatorDepositAssetCash = debtOutstanding;
            mustLiquidateFullAmount = true;
        }
    }

    /// @notice Executes a trade on the AMM.
    /// @param currencyId id of the vault borrow currency
    /// @param maturity maturity to lend or borrow at
    /// @param netfCashToAccount positive if lending, negative if borrowing
    /// @param rateLimit 0 if there is no limit, otherwise is a slippage limit
    /// @param blockTime current time
    /// @return netAssetCash amount of cash to credit to the account
    function executeTrade(
        uint16 currencyId,
        uint256 maturity,
        int256 netfCashToAccount,
        uint32 rateLimit,
        uint256 maxBorrowMarketIndex,
        uint256 blockTime
    ) internal returns (int256 netAssetCash) {
        uint8 maxMarketIndex = CashGroup.getMaxMarketIndex(currencyId);
        require(maxMarketIndex <= maxBorrowMarketIndex); // @dev: cannot borrow past market index
        (uint256 marketIndex, bool isIdiosyncratic) = DateTime.getMarketIndex(maxMarketIndex, maturity, blockTime);
        require(!isIdiosyncratic);

        // fCash is restricted from being larger than uint88 inside the trade module
        uint256 fCashAmount = uint256(netfCashToAccount.abs());
        require(fCashAmount < type(uint88).max);

        // Encodes trade data for the TradingAction module
        bytes32 trade = bytes32(
            (uint256(uint8(netfCashToAccount > 0 ? TradeActionType.Lend : TradeActionType.Borrow)) << 248) |
            (uint256(marketIndex) << 240) |
            (uint256(fCashAmount) << 152) |
            (uint256(rateLimit) << 120)
        );

        // Use the library here to reduce the deployed bytecode size
        netAssetCash = TradingAction.executeVaultTrade(currencyId, trade);
    }

    /// @notice Settles a vault account that has a position in a matured vault.
    /// @param vaultAccount the account's position in the vault
    /// @param vaultConfig configuration for the given vault
    /// @param blockTime current block time
    /// @return strategyTokenClaim the amount of strategy tokens the account has left over
    function settleVaultAccount(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 blockTime
    ) internal returns (uint256 strategyTokenClaim) {
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, vaultAccount.maturity);
        require(vaultState.isSettled, "Not Settled");

        AssetRateParameters memory settlementRate = AssetRate.buildSettlementRateStateful(
            vaultConfig.borrowCurrencyId,
            vaultAccount.maturity,
            blockTime
        );

        // Value of all strategy tokens at a snapshot price from settlement. The current spot price may be
        // different but the spot price will be irrelevant post settlement. Settlement prices should be oracle
        // prices and should not be manipulate-able via flash loans. This is a requirement in strategy vault design.
        // Even if the settlement price was manipulated, it's not clear how it would be used to anyone's advantage
        // here since all accounts in the pool will face the same price.
        int256 totalStrategyTokenValueAtSettlement = vaultState.totalStrategyTokens.toInt()
            .mul(vaultState.settlementStrategyTokenValue)
            .div(Constants.INTERNAL_TOKEN_PRECISION);

        int256 totalAccountValue = _getTotalAccountValueAtSettlement(
            vaultAccount,
            vaultState,
            settlementRate,
            totalStrategyTokenValueAtSettlement
        );

        // Returns the asset cash and strategy token claims the account has on the settled maturity
        int256 assetCashClaim;
        (assetCashClaim, strategyTokenClaim) = _getAccountClaimsOnSettledMaturity(
            vaultConfig,
            vaultState,
            settlementRate,
            totalAccountValue,
            totalStrategyTokenValueAtSettlement
        );

        // Update the vault account in memory
        vaultAccount.fCash = 0;
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(assetCashClaim);
        vaultAccount.vaultShares = 0;
        vaultAccount.maturity = 0;
    }

    /// @notice Returns the total account value at settlement
    function _getTotalAccountValueAtSettlement(
        VaultAccount memory vaultAccount, 
        VaultState memory vaultState, 
        AssetRateParameters memory settlementRate,
        int256 totalStrategyTokenValueAtSettlement
    ) private pure returns (int256 totalAccountValue) {
        // This is the total value of all vault shares at settlement as the sum of cash and strategy token
        // assets held in the vault maturity using prices snapshot at settlement. Any future prices changes
        // on these assets will not be relevant in our calculations so there is no incentive to "game" when
        // users settle their positions.
        int256 totalVaultShareValueAtSettlement = totalStrategyTokenValueAtSettlement
            .add(settlementRate.convertToUnderlying(vaultState.totalAssetCash.toInt()));

        // The account's value at settlement is used to determine how much resulting shares of cash and
        // strategy tokens it is allowed to withdraw from the pool of assets.
        // totalAccountValue = vaultShares * settlementVaultShareValue + fCash (fCash is negative)
        totalAccountValue = 
            vaultAccount.vaultShares.toInt().mul(totalVaultShareValueAtSettlement)
                .div(vaultState.totalVaultShares.toInt())
            .add(vaultAccount.fCash);

        // If the total account value is negative than it is insolvent at settlement. This can happen if
        // the vault as a whole has repaid its debts but one of the accounts in the vault does not have
        // sufficient assets to repay its share of debts. If that account is attempting to settle (unlikely),
        // then clear its claims on the pool and attempt to recover the cash balance from the account by marking
        // it on the temporary cash balance. If the account is attempting to exit, it will be unable to redeem
        // any strategy tokens (there would be no claim) and then the protocol would attempt to transfer tokens
        // from the account. If the account is attempting to enter, this insolvency would be net off against any
        // borrowing or deposits. An account cannot roll with a matured position.
        if (totalAccountValue < 0) {
            vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(
                settlementRate.convertFromUnderlying(totalAccountValue)
            );
            totalAccountValue = 0;
        }
    }

    /// @notice Returns the account's claims on a settled maturity. Resolves any shortfalls due to insolvent
    /// accounts within the same maturity.
    function _getAccountClaimsOnSettledMaturity(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        AssetRateParameters memory settlementRate,
        int256 totalAccountValue,
        int256 totalStrategyTokenValueAtSettlement
    ) private returns (int256 assetCashClaim, uint256 strategyTokenClaim) {
        {
            // Represents any asset cash in surplus of what is required to repay total fCash debt
            int256 residualAssetCashBalance = vaultState.totalAssetCash.toInt()
                .add(settlementRate.convertFromUnderlying(vaultState.totalfCash));
                
            // Represents the total value of the vault at settlement after repaying fCash debt
            int256 settledVaultValue = settlementRate.convertToUnderlying(residualAssetCashBalance)
                .add(totalStrategyTokenValueAtSettlement);
            
            strategyTokenClaim = totalAccountValue.mul(vaultState.totalStrategyTokens.toInt())
                .div(settledVaultValue).toUint();

            assetCashClaim = totalAccountValue.mul(residualAssetCashBalance)
                .div(settledVaultValue);
        } 

        // Decrement counters for settled assets that have been distributed, resolving any shortfalls
        // if the counters decrease to zero.
        VaultSettledAssetsStorage storage settledAssets = LibStorage.getVaultSettledAssets()
            [vaultConfig.vault][vaultState.maturity];
        uint256 remainingStrategyTokens = settledAssets.remainingStrategyTokens;
        int256 remainingAssetCash = int256(uint256(settledAssets.remainingAssetCash));
        
        if (remainingStrategyTokens < strategyTokenClaim) {
            // If there are insufficient strategy tokens to repay the account, we convert it to a cash claim at the
            // settlement value. This is an unfortunate consequence that solvent accounts face if there is a single
            // account insolvency. The initial accounts to settle will be ok but the last account to settle will have to
            // take their profits in cash, not strategy tokens.
            assetCashClaim = assetCashClaim.add(settlementRate.convertFromUnderlying(
                (strategyTokenClaim - remainingStrategyTokens).toInt() // overflow checked above
                    .mul(vaultState.settlementStrategyTokenValue)
                    .div(Constants.INTERNAL_TOKEN_PRECISION)
            ));
            strategyTokenClaim = remainingStrategyTokens;

            // Clear the remaining strategy tokens
            settledAssets.remainingStrategyTokens = 0;
        } else {
            // Underflow checked above, cannot overflow uint80
            settledAssets.remainingStrategyTokens = uint80(remainingStrategyTokens - strategyTokenClaim);
        }

        if (remainingAssetCash < assetCashClaim) {
            // If there is insufficient asset cash to repay the account then we need to raise cash from the reserve.
            int256 assetCashRaised = VaultConfiguration.resolveShortfallWithReserve(
                vaultConfig.vault, vaultConfig.borrowCurrencyId, (assetCashClaim - remainingAssetCash)
            );

            assetCashClaim = remainingAssetCash.add(assetCashRaised);

            // Clear the remaining asset cash
            settledAssets.remainingAssetCash = 0;
        } else {
            // Underflow checked above, cannot overflow uint80
            settledAssets.remainingAssetCash = uint80(remainingAssetCash - assetCashClaim);
        }
    }
}
