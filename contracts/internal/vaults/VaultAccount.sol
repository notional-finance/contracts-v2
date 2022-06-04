// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {VaultAccount, VaultAccountStorage, TradeActionType} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {TradingAction} from "../../external/actions/TradingAction.sol";
import {DateTime} from "../markets/DateTime.sol";

import {CashGroup, CashGroupParameters, Market, MarketParameters} from "../markets/CashGroup.sol";
import {AssetRate, AssetRateParameters} from "../markets/AssetRate.sol";
import {TokenType, Token, TokenHandler, AaveHandler} from "../balances/TokenHandler.sol";

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
    using SafeMath for uint256;

    // As a storage optimization to keep VaultAccountStorage inside bytes32, we store the maturity as epochs
    // from an arbitrary start time before we've deployed this feature. This allows us to have 65536 epochs
    // which is plenty even with the smallest potential term length being 1 month (5461 years).
    function _convertEpochToMaturity(
        uint256 vaultEpoch,
        uint256 termLengthInSeconds,
        uint256 termOffsetInSeconds
    ) private pure returns (uint256 maturity) {
        if (vaultEpoch == 0) return 0;
        uint256 epochOffset = Constants.VAULT_EPOCH_START.add(termOffsetInSeconds);

        maturity = vaultEpoch.mul(termLengthInSeconds).add(epochOffset);
    }

    function _convertMaturityToEpoch(
        uint256 maturity,
        uint256 termLengthInSeconds,
        uint256 termOffsetInSeconds
    ) private pure returns (uint16) {
        if (maturity == 0) return 0;

        require(maturity % termLengthInSeconds == 0);
        uint256 epochOffset = Constants.VAULT_EPOCH_START.add(termOffsetInSeconds);
        uint256 vaultEpoch = maturity.sub(epochOffset).div(termLengthInSeconds);
        require(vaultEpoch <= type(uint16).max);

        return uint16(vaultEpoch);
    }

    /// @notice Returns a single account's vault position
    function getVaultAccount(address account, VaultConfig memory vaultConfig)
        internal
        view
        returns (VaultAccount memory vaultAccount)
    {
        mapping(address => mapping(address => VaultAccountStorage)) storage store = LibStorage
            .getVaultAccount();
        VaultAccountStorage storage s = store[account][vaultConfig.vault];

        // fCash is negative on the stack
        vaultAccount.fCash = -int256(uint256(s.fCash));
        vaultAccount.escrowedAssetCash = int256(uint256(s.escrowedAssetCash));
        vaultAccount.maturity = _convertEpochToMaturity(s.vaultEpoch,
            vaultConfig.termLengthInSeconds, vaultConfig.termOffsetInSeconds);
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
        // accounts that become insolvent or require manual settlements which will require expensive
        // transactions.
        require(vaultAccount.fCash == 0 || vaultConfig.minAccountBorrowSize <= vaultAccount.fCash.neg(), "Min Borrow");

        s.fCash = VaultStateLib.safeUint80(vaultAccount.fCash.neg());
        s.escrowedAssetCash = VaultStateLib.safeUint80(vaultAccount.escrowedAssetCash);
        s.vaultShares = VaultStateLib.safeUint80(vaultAccount.vaultShares);
        s.vaultEpoch = _convertMaturityToEpoch(vaultAccount.maturity,
            vaultConfig.termLengthInSeconds, vaultConfig.termOffsetInSeconds);
    }

    /**
     * @notice Settles a vault account that has a position in a matured vault. This clears
     * the fCash balance off both the vault account and the vault state, crediting back to
     * the vault account any excess asset cash they have accrued since the settlement.
     * @param vaultAccount the account's position in the vault
     * @param vaultConfig configuration for the given vault
     * @param blockTime current block time
     */
    function settleVaultAccount(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 blockTime,
        bool requiresSettlementPrior
    ) internal {
        // These conditions mean that the vault account does not require settlement
        if (blockTime < vaultAccount.maturity || vaultAccount.fCash == 0) return;

        if (requiresSettlementPrior == false) {
            // A vault must be fully settled for an account to settle. Most vaults should be able to settle
            // to be fully settled before maturity. However, some vaults may expect fCash to have matured before
            // they can settle (i.e. some vaults may be trading between two fCash currencies). Those vaults must
            // be settled within 24 hours of maturity expiration and before the staked nToken unstaking window begins.
            // For accounts that are within these vaults, they will face a period of time (< 24 hours) where they cannot
            // exit until the vault is settled. Vault settlement should be permissionless so this should not create
            // significant issues.
            require(vaultState.isFullySettled, "Vault not settled");

            // Update the vault account in memory
            vaultAccount.fCash = 0;

            // At this point, the account has cleared its fCash balance on the vault and can re-enter a new vault maturity.
            // In all likelihood, it still has some balance of vaultShares on the vault. If it wants to re-enter a vault
            // these shares will be considered as part of its netAssetValue for its collateral ratio.
        } else {
            AssetRateParameters memory settlementRate = AssetRate.buildSettlementRateStateful(
                vaultConfig.borrowCurrencyId,
                vaultAccount.maturity,
                blockTime
            );
            settleEscrowedAccount(vaultAccount, vaultState, settlementRate);
        }
    }

    function settleEscrowedAccount(
        VaultAccount memory vaultAccount,
        VaultState memory vaultState,
        AssetRateParameters memory settlementRate
    ) internal pure {
        // This is a positive number
        int256 assetCashToRepayfCash = settlementRate.convertFromUnderlying(vaultAccount.fCash).neg();

        // The temporary cash balance is now any cash remaining after repayment of the debt.
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance
            .add(vaultAccount.escrowedAssetCash)
            .sub(assetCashToRepayfCash);
        
        // This balance has now been applied to the account
        vaultAccount.escrowedAssetCash = 0;

        // In both cases remove the totalfCash from the vault state
        vaultState.totalfCash = vaultState.totalfCash.sub(vaultAccount.fCash);
        
        // fCash is zeroed out here no matter what, the tempCashBalance will represent the net
        // cash the account has a credit for or owes the protocol.
        vaultAccount.fCash = 0;

        if (vaultAccount.tempCashBalance < 0) {
            // If there are vault shares left then this will revert, more vault shares
            // need to be sold to exit the account's debt.
            require(vaultAccount.vaultShares == 0);

            // If there are no vault shares left at this point then we have an
            // insolvency. The negative cash balance needs to be cleared via nToken
            // redemption. The tempCashBalance will represent the amount the account
            // has left to repay.

            // If we are inside borrowIntoVault, it will revert since we do not
            // clear the maturity here. That is the correct behavior.  If we are
            // inside exitVault, then it will revert.
        } else if (vaultState.accountsRequiringSettlement > 0) {
            // If we reach this point the account has been cleared of needing settlement, we don't
            // want to revert on underflow here, just floor the value at 0 in case we somehow miss
            // an insolvent account in tracking.
            vaultState.accountsRequiringSettlement -= 1;
        }
    }

    function borrowAndEnterVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 maturity,
        uint256 fCashToBorrow,
        uint32 maxBorrowRate,
        bytes calldata vaultData
    ) internal {
        // The vault account can only be increasing their borrow position or not have one set. If they
        // are increasing their position they will be in the current maturity. We won't update the
        // maturity in this method, it will be updated when we enter the maturity pool at the end
        // of the parent method borrowAndEnterVault
        require(vaultAccount.maturity == maturity || vaultAccount.fCash == 0);
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, maturity);
        bool usedEscrowedAssetCash = false;

        // Put all of the escrowed asset cash into the temp cash balance and attempt to enter with it. This will
        // trigger a collateral check at the end of the method because the collateral ratio of the account may
        // decrease as a result.
        if (vaultAccount.escrowedAssetCash > 0) {
            usedEscrowedAssetCash = true;
            removeEscrowedAssetCash(vaultAccount, vaultState);
        }

        // Borrows fCash and puts the cash balance into the vault account's temporary cash balance
        if (fCashToBorrow > 0) {
            _borrowIntoVault(
                vaultAccount,
                vaultConfig,
                vaultState,
                maturity,
                SafeInt256.toInt(fCashToBorrow).neg(),
                maxBorrowRate,
                block.timestamp
            );
        }

        // Migrates the account from its old pool to the new pool if required, updates the current
        // pool and deposits asset tokens into the vault
        vaultState.enterMaturityPool(vaultAccount, vaultConfig, vaultData);

        // Set the vault state and account in storage and check the vault's collateral ratio
        vaultState.setVaultState(vaultConfig.vault);
        setVaultAccount(vaultAccount, vaultConfig);
            
        if (fCashToBorrow > 0 || usedEscrowedAssetCash) {
            vaultConfig.checkCollateralRatio(vaultState, vaultAccount.vaultShares, vaultAccount.fCash, vaultAccount.escrowedAssetCash);
        }

        // If the account is not using any leverage (fCashToBorrow == 0) we don't check the collateral ratio, no matter
        // what the amount is the collateral ratio will increase. This is useful for accounts that want to quickly and cheaply
        // deleverage their account without paying down debts.
    }

    /**
     * @notice Borrows fCash to enter a vault, checks the collateral ratio and pays the nToken fee
     * @dev Updates vault fCash in storage, updates vaultAccount in memory
     * @param vaultAccount the account's position in the vault
     * @param vaultConfig configuration for the given vault
     * @param maturity the maturity to enter for the vault
     * @param fCash amount of fCash to borrow from the market, must be negative
     * @param maxBorrowRate maximum annualized rate to pay for the borrow
     * @param blockTime current block time
     */
    function _borrowIntoVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 maturity,
        int256 fCash,
        uint32 maxBorrowRate,
        uint256 blockTime
    ) private {
        require(fCash < 0); // dev: fcash must be negative

        {
            int256 assetCashBorrowed  = _executeTrade(
                vaultConfig.borrowCurrencyId,
                maturity,
                fCash,
                maxBorrowRate,
                blockTime
            );
            require(assetCashBorrowed > 0, "Borrow failed");

            // Update the account and vault state to account for the borrowing
            vaultState.totalfCash = vaultState.totalfCash.add(fCash);
            vaultState.totalfCashRequiringSettlement = vaultState.totalfCashRequiringSettlement.add(fCash);
            vaultAccount.fCash = vaultAccount.fCash.add(fCash);
            vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(assetCashBorrowed);
        }

        // Ensure that we are above the minimum borrow size. Accounts smaller than this are not profitable
        // to unwind if we need to liquidate.
        require(vaultConfig.minAccountBorrowSize <= vaultAccount.fCash.neg(), "Min Borrow");

        // Will reduce the tempCashBalance based on the assessed vault fee
        uint256 timeToMaturity = maturity.sub(blockTime);
        vaultConfig.assessVaultFees(vaultAccount, fCash, timeToMaturity);

        // This will check if the vault can sustain the total borrow capacity given the staked nToken value.
        vaultConfig.checkTotalBorrowCapacity(vaultState, blockTime);
    }

    function redeemVaultSharesAndLend(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        uint256 vaultSharesToRedeem,
        int256 fCashToLend,
        uint32 minLendRate,
        bytes calldata vaultData
    ) internal returns (VaultState memory vaultState) {
        vaultState = VaultStateLib.getVaultState(vaultConfig.vault, vaultAccount.maturity);
        // If a vault is redeeming its entire vault shares balance after settlement it may trip the
        // requiresSettlement check because its vaultShares is zero and it still has an fCash balance
        // prior to setting the vault account's fCash to zero. Save off the requiresSettlement flag
        // prior to strategyToken redemption.
        bool requiresSettlementPrior = requiresSettlement(vaultAccount);
        // When an account exits the maturity pool it may get some asset cash credited to its temp
        // cash balance and it will sell the strategy tokens it has a claim on.
        uint256 strategyTokens = vaultState.exitMaturityPool(vaultAccount, vaultSharesToRedeem);

        // Redeems and updates temp cash balance
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(
            vaultConfig.redeem(strategyTokens, vaultState.maturity, vaultData)
        );

        if (vaultAccount.maturity <= block.timestamp) {
            settleVaultAccount(vaultAccount, vaultConfig, vaultState, block.timestamp, requiresSettlementPrior);
            require(requiresSettlement(vaultAccount) == false); // dev: unsuccessful settlement
        } else if (fCashToLend > 0) {
            _lendToExitVault(
                vaultAccount,
                vaultConfig,
                vaultState,
                fCashToLend,
                minLendRate,
                block.timestamp
            );
        }

        vaultState.setVaultState(vaultConfig.vault);

        // Don't set the account here, depending on roll or exit we have different mechanics. We also don't
        // check collateral ratio here, during roll it will happen at the end. During exit it will happen just after
        // this method completes
    }

    /**
     * @notice Allows an account to exit a vault term prematurely by lending fCash.
     * @dev Updates vault fCash in storage, updates vaultAccount in memory.
     * @param vaultAccount the account's position in the vault
     * @param vaultConfig configuration for the given vault
     * @param fCash amount of fCash to lend from the market, must be positive and cannot
     * lend more than the account's debt
     * @param minLendRate minimum rate to lend at
     * @param blockTime current block time
     */
    function _lendToExitVault(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        int256 fCash,
        uint32 minLendRate,
        uint256 blockTime
    ) private {
        // Don't allow the vault to lend to positive fCash
        require(vaultAccount.fCash.add(fCash) <= 0); // dev: cannot lend to positive fCash
        
        // Check that the account is in an active vault
        require(blockTime < vaultAccount.maturity);
        
        // Returns the cost in asset cash terms to lend an offsetting fCash position
        // so that the account can exit. assetCashRequired is negative here.
        int256 assetCashCostToLend  = _executeTrade(
            vaultConfig.borrowCurrencyId,
            vaultAccount.maturity,
            fCash,
            minLendRate,
            blockTime
        );

        if (assetCashCostToLend == 0) {
            // In this case, the lending has failed due to a lack of liquidity or negative interest rates. In this
            // case just just net off the the asset cash balance and the account will forgo any money market interest
            // accrued between now and maturity.
            
            // The alternative to this is to put the assetCashDeposit into escrowed asset cash, however, this adds to
            // the complexity of the solution and may result in more complex settlement dynamics. If this scenario were
            // to occur, it is most likely that interest rates are near zero suggesting that money market interest rates
            // are also near zero (therefore the account is really not giving up much by forgoing money market interest).

            assetCashCostToLend = vaultConfig.assetRate.convertFromUnderlying(fCash).neg(); // this is a negative number
        }
        require(assetCashCostToLend <= 0);

        // Net off the cash balance required and remove the fcash. It's possible
        // that cash balance is negative here. If that is the case then we need to
        // transfer in sufficient cash to get the balance up to 0.
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(assetCashCostToLend);

        // Update fCash state on the account and the vault
        vaultAccount.fCash = vaultAccount.fCash.add(fCash);
        vaultState.totalfCash = vaultState.totalfCash.add(fCash);

        if (vaultAccount.escrowedAssetCash == 0) {
            // When there is no escrowed asset cash, the fCash must also be applied to the settlement
            // requirement.
            vaultState.totalfCashRequiringSettlement = vaultState.totalfCashRequiringSettlement.add(fCash);
        } else {
            // Apply all of the escrowed asset cash against the account to exit. We don't allow partial
            // applications of escrowed asset cash because that complicates settlement dynamics.
            removeEscrowedAssetCash(vaultAccount, vaultState);
        }
    }

    /**
     * @notice An account requires settlement if it has escrowedAssetCash (has been liquidated or failed to lend to exit
     * in an fCash market) or if it has fCash debt but no vault shares (it is insolvent).
     */
    function requiresSettlement(
        VaultAccount memory vaultAccount
    ) internal pure returns (bool) {
        return vaultAccount.escrowedAssetCash > 0 || (vaultAccount.fCash < 0 && vaultAccount.vaultShares == 0) ;
    }

    /**
     * @notice Called in the two places that would trigger an account to require settlement, during liquidation
     * and in a failed lending attempt.
     */
    function increaseEscrowedAssetCash(
        VaultAccount memory vaultAccount,
        VaultState memory vaultState,
        int256 assetCashDeposit
    ) internal pure {
        require(assetCashDeposit > 0);
        if (requiresSettlement(vaultAccount) == false) {
            // If this flag is not set then on the account then we set it up for individual settlement. The
            // account's individual fCash is now removed from the pool and not considered for pooled settlement.
            vaultState.totalfCashRequiringSettlement = vaultState.totalfCashRequiringSettlement.sub(vaultAccount.fCash);
            vaultState.accountsRequiringSettlement = vaultState.accountsRequiringSettlement.add(1);
        }

        // Move the asset cash deposit into the escrowed asset cash
        vaultAccount.escrowedAssetCash = vaultAccount.escrowedAssetCash.add(assetCashDeposit);
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.sub(assetCashDeposit);

    }

    /**
     * @notice Called in the two places where escrowed cash is reduced on the account, when an account
     * re-enters a vault and when it is is able to successfully lend to exit the vault
     */
    function removeEscrowedAssetCash(
        VaultAccount memory vaultAccount,
        VaultState memory vaultState
    ) internal pure {
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(vaultAccount.escrowedAssetCash);
        vaultAccount.escrowedAssetCash = 0;
        vaultState.accountsRequiringSettlement = vaultState.accountsRequiringSettlement.sub(1);
        // Add the account's remaining fCash back into the vault state for pooled settlement
        vaultState.totalfCashRequiringSettlement = vaultState.totalfCashRequiringSettlement.add(vaultAccount.fCash);
    }

    /**
     * @notice Executes a trade on the AMM.
     * @param currencyId id of the vault borrow currency
     * @param maturity maturity to lend or borrow at
     * @param netfCashToAccount positive if lending, negative if borrowing
     * @param rateLimit 0 if there is no limit, otherwise is a slippage limit
     * @param blockTime current time
     * @return netAssetCash amount of cash to credit to the account
     */
    function _executeTrade(
        uint16 currencyId,
        uint256 maturity,
        int256 netfCashToAccount,
        uint32 rateLimit,
        uint256 blockTime
    ) private returns (int256 netAssetCash) {
        uint8 maxMarketIndex = CashGroup.getMaxMarketIndex(currencyId);
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

    /**
     * @notice Deposits a specified amount from the account
     * @param vaultAccount vault account object
     * @param transferFrom address to transfer the tokens from
     * @param borrowCurrencyId the currency id to transfer
     * @param _depositAmountExternal the amount to deposit in external precision
     * @param useUnderlying if true then use the underlying token
     */
    function depositIntoAccount(
        VaultAccount memory vaultAccount,
        address transferFrom,
        uint16 borrowCurrencyId,
        uint256 _depositAmountExternal,
        bool useUnderlying
    ) internal {
        if (_depositAmountExternal == 0) return;
        int256 depositAmountExternal = SafeInt256.toInt(_depositAmountExternal);

        Token memory assetToken = TokenHandler.getAssetToken(borrowCurrencyId);
        int256 assetAmountExternal;

        if (useUnderlying) {
            Token memory underlyingToken = TokenHandler.getUnderlyingToken(borrowCurrencyId);
            // This is the actual amount of underlying transferred
            int256 underlyingAmountExternal = underlyingToken.transfer(
                transferFrom,
                borrowCurrencyId,
                depositAmountExternal
            );

            // This is the actual amount of asset tokens minted
            assetAmountExternal = assetToken.mint(
                borrowCurrencyId,
                SafeInt256.toUint(underlyingAmountExternal)
            );
        } else {
            if (assetToken.tokenType == TokenType.aToken) {
                // Handles special accounting requirements for aTokens
                depositAmountExternal = AaveHandler.convertToScaledBalanceExternal(
                    borrowCurrencyId,
                    depositAmountExternal
                );
            }

            assetAmountExternal = assetToken.transfer(
                transferFrom,
                borrowCurrencyId,
                depositAmountExternal
            );
        }

        // TODO: potential off by one errors here in transfer temp cash balance
        vaultAccount.tempCashBalance = vaultAccount.tempCashBalance.add(
            assetToken.convertToInternal(assetAmountExternal)
        );
    }

    /**
     * @notice Transfers into and out of an account's temporary cash balance
     * @param vaultAccount vault account object
     * @param borrowCurrencyId the currency id to transfer
     * @param useUnderlying if true then use the underlying token
     */
    function transferTempCashBalance(
        VaultAccount memory vaultAccount,
        uint16 borrowCurrencyId,
        bool useUnderlying
    ) internal {
        Token memory assetToken = TokenHandler.getAssetToken(borrowCurrencyId);
        // If tempCashBalance > 0 then we want to transfer it back to the user, and the netTransferAmount will be < 0,
        // considered from the Notional perspective.
        // If tempCashBalance < 0 then we want to pull tokens from the account and then netTransferAmount will be > 0,
        // considered from the Notional perspective.
        int256 netTransferAmountExternal = assetToken.convertToExternal(vaultAccount.tempCashBalance.neg());

        if (netTransferAmountExternal < 0) {
            if (useUnderlying) {
                assetToken.redeem(borrowCurrencyId, vaultAccount.account, SafeInt256.toUint(netTransferAmountExternal.neg()));
            } else {
                assetToken.transfer(vaultAccount.account, borrowCurrencyId, netTransferAmountExternal);
            }
            vaultAccount.tempCashBalance = 0;
        } else {
            return depositIntoAccount(
                vaultAccount,
                vaultAccount.account,
                borrowCurrencyId,
                netTransferAmountExternal.toUint(),
                useUnderlying
            );
        }

    }
}
