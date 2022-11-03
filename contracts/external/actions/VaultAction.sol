// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {ActionGuards} from "./ActionGuards.sol";
import {IVaultAction} from "../../../interfaces/notional/IVaultController.sol";
import "../../internal/vaults/VaultConfiguration.sol";
import "../../internal/vaults/VaultAccount.sol";
import {VaultStateLib, VaultState} from "../../internal/vaults/VaultState.sol";

import {LibStorage} from "../../global/LibStorage.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

contract VaultAction is ActionGuards, IVaultAction {
    using VaultConfiguration for VaultConfig;
    using VaultAccountLib for VaultAccount;
    using VaultStateLib for VaultState;
    using AssetRate for AssetRateParameters;
    using TokenHandler for Token;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    /// @notice Updates or lists a deployed vault along with its configuration.
    /// @param vaultAddress address of deployed vault
    /// @param vaultConfig struct of vault configuration
    /// @param maxPrimaryBorrowCapacity maximum borrow capacity
    function updateVault(
        address vaultAddress,
        VaultConfigStorage calldata vaultConfig,
        uint80 maxPrimaryBorrowCapacity
    ) external override onlyOwner {
        VaultConfiguration.setVaultConfig(vaultAddress, vaultConfig);
        VaultConfiguration.setMaxBorrowCapacity(vaultAddress, vaultConfig.borrowCurrencyId, maxPrimaryBorrowCapacity);
        bool enabled = (vaultConfig.flags & VaultConfiguration.ENABLED) == VaultConfiguration.ENABLED;
        emit VaultUpdated(vaultAddress, enabled, maxPrimaryBorrowCapacity);
    }

    /// @notice Enables or disables a vault. If a vault is disabled, no one can enter
    /// the vault but exits are still possible.
    /// @param vaultAddress address of deployed vault
    /// @param enable true if the vault should be enabled immediately
    function setVaultPauseStatus(
        address vaultAddress,
        bool enable
    ) external override onlyOwner {
        VaultConfiguration.setVaultEnabledStatus(vaultAddress, enable);
        emit VaultPauseStatus(vaultAddress, enable);
    }

    /// @notice Enables or disables deleverage on a vault.
    /// @param vaultAddress address of deployed vault
    /// @param disableDeleverage true if the vault deleverage should be disabled
    function setVaultDeleverageStatus(
        address vaultAddress,
        bool disableDeleverage
    ) external override onlyOwner {
        VaultConfiguration.setVaultDeleverageStatus(vaultAddress, disableDeleverage);
        emit VaultDeleverageStatus(vaultAddress, disableDeleverage);
    }

    /// @notice Whitelists a secondary borrow currency for a vault, vaults can borrow up to the capacity
    /// using the `borrowSecondaryCurrencyToVault` and `repaySecondaryCurrencyToVault` methods. Vaults that
    /// use a secondary currency must ALWAYS repay the secondary debt during redemption and handle accounting
    /// for the secondary currency themselves.
    /// @param vaultAddress address of deployed vault
    /// @param secondaryCurrencyId struct of vault configuration
    /// @param maxBorrowCapacity maximum borrow capacity
    function updateSecondaryBorrowCapacity(
        address vaultAddress,
        uint16 secondaryCurrencyId,
        uint80 maxBorrowCapacity
    ) external override onlyOwner {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vaultAddress);
        // Tokens with transfer fees create lots of issues with vault mechanics, we prevent them
        // from being listed here.
        Token memory assetToken = TokenHandler.getAssetToken(secondaryCurrencyId);
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(secondaryCurrencyId);
        require(!assetToken.hasTransferFee && !underlyingToken.hasTransferFee); 

        // The secondary borrow currency must be white listed on the configuration before we can set a max
        // capacity.
        require(
            secondaryCurrencyId == vaultConfig.secondaryBorrowCurrencies[0] ||
            secondaryCurrencyId == vaultConfig.secondaryBorrowCurrencies[1],
            "Invalid Currency"
        );

        VaultConfiguration.setMaxBorrowCapacity(vaultAddress, secondaryCurrencyId, maxBorrowCapacity);
        emit VaultUpdateSecondaryBorrowCapacity(vaultAddress, secondaryCurrencyId, maxBorrowCapacity);
    }


    /// @notice Allows the owner to reduce the max borrow capacity on the vault
    /// @param vaultAddress address of the vault
    /// @param maxVaultBorrowCapacity the new max vault borrow capacity on the primary currency
    function setMaxBorrowCapacity(
        address vaultAddress,
        uint80 maxVaultBorrowCapacity
    ) external override onlyOwner {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vaultAddress);
        VaultConfiguration.setMaxBorrowCapacity(vaultAddress, vaultConfig.borrowCurrencyId, maxVaultBorrowCapacity);

        emit VaultUpdated(vaultAddress, vaultConfig.getFlag(VaultConfiguration.ENABLED), maxVaultBorrowCapacity);
    }

    /// @notice Allows the owner to reduce the max borrow capacity on the vault and force
    /// the redemption of strategy tokens to cash to reduce the overall risk of the vault.
    /// This method is intended to be used in emergencies to mitigate insolvency risk. The effect
    /// of this method will mean that the overall max borrow capacity is reduced, the total used
    /// capacity will be unchanged (redeemStrategyTokensToCash does not do any lending to reduce
    /// the outstanding fCash), and accounts will be locked out of entering the maturity which was
    /// targeted by this method. Other maturities for that vault may still be entered depending on
    /// whether or not the vault is above or below the max vault borrow capacity.
    /// @param vaultAddress address of the vault
    /// @param maxVaultBorrowCapacity the new max vault borrow capacity on the primary currency
    /// @param maturity the maturity to redeem tokens in, will generally be either the current
    /// maturity or the next maturity.
    /// @param strategyTokensToRedeem how many tokens we would want to redeem in the maturity
    /// @param vaultData vault data to pass to the vault
    function reduceMaxBorrowCapacity(
        address vaultAddress,
        uint80 maxVaultBorrowCapacity,
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata vaultData
    ) external override onlyOwner {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vaultAddress);
        VaultConfiguration.setMaxBorrowCapacity(vaultAddress, vaultConfig.borrowCurrencyId, maxVaultBorrowCapacity);

        // Redeems strategy tokens to be held against fCash debt
        _redeemStrategyTokensToCashInternal(vaultConfig, maturity, strategyTokensToRedeem, vaultData);

        emit VaultUpdated(vaultAddress, vaultConfig.getFlag(VaultConfiguration.ENABLED), maxVaultBorrowCapacity);
    }

    /// @notice Strategy vaults can call this method to redeem strategy tokens to cash and hold them
    /// as asset cash within the pool. This should typically be used during settlement but can also be
    /// used for vault-wide deleveraging.
    /// @param maturity the maturity of the vault where the redemption will take place
    /// @param strategyTokensToRedeem the number of strategy tokens redeemed
    /// @param vaultData arbitrary data to pass back to the vault
    /// @return assetCashRequiredToSettle amount of asset cash still remaining to settle the debt
    /// @return underlyingCashRequiredToSettle amount of underlying cash still remaining to settle the debt
    function redeemStrategyTokensToCash(
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata vaultData
    ) external override returns (int256 assetCashRequiredToSettle, int256 underlyingCashRequiredToSettle) {
        // NOTE: this call must come from the vault itself
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(msg.sender);
        // NOTE: if the msg.sender is not the vault itself this will revert
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Paused");
        return _redeemStrategyTokensToCashInternal(vaultConfig, maturity, strategyTokensToRedeem, vaultData);
    }

    /// @notice Redeems strategy tokens to cash
    function _redeemStrategyTokensToCashInternal(
        VaultConfig memory vaultConfig,
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata vaultData
    ) private nonReentrant returns (int256 assetCashRequiredToSettle, int256 underlyingCashRequiredToSettle) {
        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, maturity);
        (int256 assetCashReceived, uint256 underlyingToReceiver) = vaultConfig.redeemWithoutDebtRepayment(
            vaultConfig.vault, strategyTokensToRedeem, maturity, vaultData
        );
        require(assetCashReceived > 0);
        // Safety check to ensure that the vault does not somehow receive tokens in this scenario
        require(underlyingToReceiver == 0);

        vaultState.totalAssetCash = vaultState.totalAssetCash.add(uint256(assetCashReceived));
        vaultState.totalStrategyTokens = vaultState.totalStrategyTokens.sub(strategyTokensToRedeem);
        vaultState.setVaultState(vaultConfig.vault);

        emit VaultRedeemStrategyToken(vaultConfig.vault, maturity, assetCashReceived, strategyTokensToRedeem);
        return _getCashRequiredToSettle(vaultConfig, vaultState, maturity);
    }

    /// @notice Strategy vaults can call this method to deposit asset cash into strategy tokens.
    /// @param maturity the maturity of the vault where the redemption will take place
    /// @param assetCashInternal the number of asset cash tokens to deposit (external)
    /// @param vaultData arbitrary data to pass back to the vault for deposit
    function depositVaultCashToStrategyTokens(
        uint256 maturity,
        uint256 assetCashInternal,
        bytes calldata vaultData
    ) external override nonReentrant {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(msg.sender);
        // NOTE: if the msg.sender is not the vault itself this will revert
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Paused");

        // If the vault allows further re-entrancy then set the status back to the default
        if (vaultConfig.getFlag(VaultConfiguration.ALLOW_REENTRANCY)) {
            reentrancyStatus = _NOT_ENTERED;
        }

        VaultState memory vaultState = VaultStateLib.getVaultState(msg.sender, maturity);
        uint256 strategyTokensMinted = vaultConfig.deposit(
            vaultConfig.vault, assetCashInternal.toInt(), maturity, 0, vaultData
        );

        vaultState.totalAssetCash = vaultState.totalAssetCash.sub(assetCashInternal);
        vaultState.totalStrategyTokens = vaultState.totalStrategyTokens.add(strategyTokensMinted);
        vaultState.setVaultState(msg.sender);

        // When exchanging asset cash for strategy tokens we will decrease the vault's collateral, ensure that
        // we don't go under the configured minimum here.
        (int256 collateralRatio, /* */) = vaultConfig.calculateCollateralRatio(
            vaultState, msg.sender, vaultState.totalVaultShares, vaultState.totalfCash
        );
        require(vaultConfig.minCollateralRatio <= collateralRatio, "Insufficient Collateral");
        emit VaultMintStrategyToken(msg.sender, maturity, assetCashInternal, strategyTokensMinted);
    }

    /// @notice Allows a vault to borrow a secondary currency if it is whitelisted to do so
    /// @param account account that is borrowing the secondary currency
    /// @param maturity the maturity to borrow at
    /// @param fCashToBorrow fCash to borrow for the first and second secondary currencies
    /// @param maxBorrowRate maximum borrow rate for the first and second secondary currencies
    /// @param minRollLendRate max roll lend rate for the first and second borrow currencies
    /// @return underlyingTokensTransferred amount of tokens transferred back to the vault
    function borrowSecondaryCurrencyToVault(
        address account,
        uint256 maturity,
        uint256[2] calldata fCashToBorrow,
        uint32[2] calldata maxBorrowRate,
        uint32[2] calldata minRollLendRate
    ) external override returns (uint256[2] memory underlyingTokensTransferred) {
        // This method call must come from the vault
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(msg.sender);
        // This also ensures that the caller is an actual vault
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Paused");
        uint16[2] memory currencies = vaultConfig.secondaryBorrowCurrencies;
        require(currencies[0] != 0 || currencies[1] != 0);

        VaultAccountSecondaryDebtShareStorage storage s = 
            LibStorage.getVaultAccountSecondaryDebtShare()[account][vaultConfig.vault];
        uint256 accountMaturity = s.maturity;
        
        // If the borrower is rolling their primary debt forward, we need to check that here and roll
        // their secondary debt forward in the same manner (simulate lending and then borrow more in
        // a longer dated maturity to repay their borrowing). Rolling debts forward can only occur if:
        //  - borrower has an existing debt position
        //  - borrower is rolling to a longer dated maturity
        //  - vault allows rolling positions forward
        //  - borrower is not the vault itself (only individual accounts can roll borrows)
        int256[2] memory costToRepay;
        if (
            accountMaturity != 0 &&
            accountMaturity < maturity &&
            vaultConfig.getFlag(VaultConfiguration.ALLOW_ROLL_POSITION) &&
            account != msg.sender
        ) {
            costToRepay[0] = _repayDuringRoll(
                vaultConfig, account, currencies[0], accountMaturity, s.accountDebtSharesOne, minRollLendRate[0]
            );
            costToRepay[1] = _repayDuringRoll(
                vaultConfig, account, currencies[1], accountMaturity, s.accountDebtSharesTwo, minRollLendRate[1]
            );
        }

        underlyingTokensTransferred[0] = _borrowAndTransfer(
            vaultConfig, account, currencies[0], maturity, costToRepay[0], fCashToBorrow[0], maxBorrowRate[0]
        );
        underlyingTokensTransferred[1] = _borrowAndTransfer(
            vaultConfig, account, currencies[1], maturity, costToRepay[1], fCashToBorrow[1], maxBorrowRate[1]
        );
    }

    function _repayDuringRoll(
        VaultConfig memory vaultConfig,
        address account,
        uint16 currencyId,
        uint256 maturity,
        uint256 accountDebtShares,
        uint32 minLendRate
    ) private returns (int256 costToRepay) {
        if (currencyId != 0 && accountDebtShares != 0) {
            (costToRepay, /* */) = vaultConfig.repaySecondaryBorrow(
                account, currencyId, maturity, accountDebtShares, minLendRate
            );
        }
    }

    function _borrowAndTransfer(
        VaultConfig memory vaultConfig,
        address account,
        uint16 currencyId,
        uint256 maturity,
        int256 costToRepay,
        uint256 fCashToBorrow,
        uint32 maxBorrowRate
    ) private returns (uint256 underlyingTokensTransferred) {
        if ((currencyId == 0 || fCashToBorrow == 0) && costToRepay == 0) return 0;

        (int256 netBorrowedCash, /* */) = vaultConfig.increaseSecondaryBorrow(
            account, currencyId, maturity, fCashToBorrow, maxBorrowRate
        );

        netBorrowedCash = netBorrowedCash.add(costToRepay);
        require(netBorrowedCash >= 0, "Insufficient Secondary Borrow");

        underlyingTokensTransferred = VaultConfiguration.transferFromNotional(
            vaultConfig.vault, currencyId, netBorrowedCash
        );
    }

    /// @notice Allows a vault to repay a secondary currency that it has borrowed. Will be executed via a callback
    /// which will request that the vault repay a specific amount of underlying tokens.
    /// @param account account that is repaying the secondary currency
    /// @param currencyId currency id of the secondary currency
    /// @param maturity the maturity to lend at
    /// @param debtSharesToRepay amount of debt shares to repay (used to calculate fCashToLend)
    /// @param minLendRate minimum lend rate
    /// @return returnData arbitrary return data to pass back to the vault
    function repaySecondaryCurrencyFromVault(
        address account,
        uint16 currencyId,
        uint256 maturity,
        uint256 debtSharesToRepay,
        uint32 minLendRate,
        bytes calldata callbackData
    ) external override returns (bytes memory returnData) {
        // Short circuits a zero debt shares to repay to save gas and avoid divide by zero issues
        if (debtSharesToRepay == 0) return returnData;

        // This method call must come from the vault
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(msg.sender);
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Paused");

        (int256 netAssetCash, /* */) = vaultConfig.repaySecondaryBorrow(
            account, currencyId, maturity, debtSharesToRepay, minLendRate
        );

        Token memory assetToken = TokenHandler.getAssetToken(currencyId);
        // The vault MUST return exactly this amount of underlying tokens to the vault in the callback. We use
        // a callback here because it is more precise and gas efficient than calculating netAssetCash twice
        uint256 balanceTransferred;
        {
            // If the asset token is NonMintable then the underlying is the same object.
            Token memory underlyingToken = assetToken.tokenType == TokenType.NonMintable ? 
                assetToken :
                TokenHandler.getUnderlyingToken(currencyId);

            uint256 underlyingExternalToRepay = underlyingToken.convertToUnderlyingExternalWithAdjustment(
                vaultConfig.assetRate.convertToUnderlying(netAssetCash).neg()
            ).toUint();

            uint256 balanceBefore = underlyingToken.balanceOf(address(this));
            // Tells the vault will redeem the strategy token amount and transfer asset tokens back to Notional
            returnData = IStrategyVault(msg.sender).repaySecondaryBorrowCallback(
                underlyingToken.tokenAddress, underlyingExternalToRepay, callbackData
            );
            uint256 balanceAfter = underlyingToken.balanceOf(address(this));
            balanceTransferred = balanceAfter.sub(balanceBefore);
            require(balanceTransferred >= underlyingExternalToRepay, "Insufficient Repay");
        }

        // NonMintable tokens do not require minting
        if (assetToken.tokenType != TokenType.NonMintable) {
            assetToken.mint(currencyId, balanceTransferred);
        }
    }

    /**
     * @notice MUST be called by vaults that are using secondary borrows to initiate the settlement
     * process. Once settlement process has been initiated, no further secondary borrows may occur in
     * this maturity. Repayments can only occur via the vault itself, individual accounts cannot repay
     * secondary borrows after this occurs. Can only be called by the vault.
     * @param maturity maturity in which to initiate settlement
     * @return secondaryBorrowSnapshot value of fCash in primary currency terms for both secondary borrow
     * currencies
     */
    function initiateSecondaryBorrowSettlement(
        uint256 maturity
    ) external override returns (uint256[2] memory secondaryBorrowSnapshot) {
        // This method call must come from the vault
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(msg.sender);
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED), "Paused");

        secondaryBorrowSnapshot[0] = vaultConfig.snapshotSecondaryBorrowAtSettlement(
            vaultConfig.secondaryBorrowCurrencies[0],
            maturity
        ).toUint();

        secondaryBorrowSnapshot[1] = vaultConfig.snapshotSecondaryBorrowAtSettlement(
            vaultConfig.secondaryBorrowCurrencies[1],
            maturity
        ).toUint();
    }

    /// @notice Settles a vault and sets the final settlement rates
    /// @param vault the vault to settle
    /// @param maturity the maturity of the vault
    function settleVault(address vault, uint256 maturity) external override nonReentrant {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        // Allow anyone to call this method unless it must be authorized by the vault. Generally speaking,
        // as long as there is sufficient cash on the vault we should be able to settle
        vaultConfig.authorizeCaller(msg.sender, VaultConfiguration.ONLY_VAULT_SETTLE);

        VaultState memory vaultState = VaultStateLib.getVaultState(vault, maturity);
        // Ensure that we are past maturity and the vault is able to settle
        require(maturity <= block.timestamp && vaultState.isSettled == false, "Cannot Settle");

        AssetRateParameters memory settlementRate = AssetRate.buildSettlementRateStateful(
            vaultConfig.borrowCurrencyId,
            maturity,
            block.timestamp
        );

        // This is how much it costs in asset cash to settle the pooled portion of the vault
        uint256 assetCashRequiredToSettle = settlementRate.convertFromUnderlying(
            vaultState.totalfCash.neg()
        ).toUint();

        // Validate that all secondary currencies have been paid off.
        mapping(uint256 => VaultSecondaryBorrowStorage) storage perCurrencyBalance =
            LibStorage.getVaultSecondaryBorrow()[vault][maturity];
        if (vaultConfig.secondaryBorrowCurrencies[0] != 0) {
            require(perCurrencyBalance[vaultConfig.secondaryBorrowCurrencies[0]].totalfCashBorrowed == 0, "Unpaid Borrow");
        }
        if (vaultConfig.secondaryBorrowCurrencies[1] != 0) {
            require(perCurrencyBalance[vaultConfig.secondaryBorrowCurrencies[1]].totalfCashBorrowed == 0, "Unpaid Borrow");
        }

        if (vaultState.totalAssetCash < assetCashRequiredToSettle) {
            // Don't allow the pooled portion of the vault to have a cash shortfall unless all
            // strategy tokens have been redeemed to asset cash.
            require(vaultState.totalStrategyTokens == 0, "Redeem all tokens");

            // After this point, we have a cash shortfall and will need to resolve it.
            // Underflow checked above
            int256 assetCashShortfall = (assetCashRequiredToSettle - vaultState.totalAssetCash).toInt();
            uint256 assetCashRaised = VaultConfiguration.resolveShortfallWithReserve(
                vaultConfig.vault, vaultConfig.borrowCurrencyId, assetCashShortfall, maturity
            ).toUint();

            vaultState.totalAssetCash = vaultState.totalAssetCash.add(assetCashRaised);
            vaultState.setVaultState(vault);
        }

        // Clears the used borrow capacity regardless of the insolvency state of the vault. Since vaults are
        // automatically paused in the case of any shortfall, no accounts will be able to enter regardless
        // but we still want to maintain proper accounting of the borrow capacity.
        VaultConfiguration.updateUsedBorrowCapacity(vault, vaultConfig.borrowCurrencyId, vaultState.totalfCash.neg());
        vaultState.setSettledVaultState(vaultConfig, settlementRate, maturity, block.timestamp);
    }

    /** View Methods **/
    function getVaultConfig(
        address vault
    ) external view override returns (VaultConfig memory vaultConfig) {
        vaultConfig = VaultConfiguration.getVaultConfigView(vault);
    }

    function getVaultState(
        address vault,
        uint256 maturity
    ) external view override returns (VaultState memory vaultState) {
        vaultState = VaultStateLib.getVaultState(vault, maturity);
    }

    function getBorrowCapacity(
        address vault,
        uint16 currencyId
    ) external view override returns (
        uint256 totalUsedBorrowCapacity,
        uint256 maxBorrowCapacity
    ) {
        VaultBorrowCapacityStorage storage cap = LibStorage.getVaultBorrowCapacity()[vault][currencyId];
        totalUsedBorrowCapacity = cap.totalUsedBorrowCapacity;
        maxBorrowCapacity = cap.maxBorrowCapacity;
    }

    function getSecondaryBorrow(
        address vault,
        uint16 currencyId,
        uint256 maturity
    ) external view override returns (
        uint256 totalfCashBorrowed,
        uint256 totalAccountDebtShares,
        uint256 totalfCashBorrowedInPrimarySnapshot
    ) {
        VaultSecondaryBorrowStorage storage balance = 
            LibStorage.getVaultSecondaryBorrow()[vault][maturity][currencyId];
        totalfCashBorrowed = balance.totalfCashBorrowed;
        totalAccountDebtShares = balance.totalAccountDebtShares;
        totalfCashBorrowedInPrimarySnapshot = balance.totalfCashBorrowedInPrimarySnapshot;
    }

    function getCashRequiredToSettle(
        address vault,
        uint256 maturity
    ) external view override returns (
        int256 assetCashRequiredToSettle,
        int256 underlyingCashRequiredToSettle
    ) {
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigView(vault);
        VaultState memory vaultState = VaultStateLib.getVaultState(vaultConfig.vault, maturity);
        return _getCashRequiredToSettle(vaultConfig, vaultState, maturity);
    }

    function _getCashRequiredToSettle(
        VaultConfig memory vaultConfig,
        VaultState memory vaultState,
        uint256 maturity
    ) private view returns (
        int256 assetCashRequiredToSettle,
        int256 underlyingCashRequiredToSettle
    ) {
        // If this is prior to maturity, it will return the current asset rate. After maturity it will
        // return the settlement rate.
        AssetRateParameters memory ar = AssetRate.buildSettlementRateView(vaultConfig.borrowCurrencyId, maturity);
        
        // If this is a positive number, there is more cash remaining to be settled.
        // If this is a negative number, there is more cash than required to repay the debt
        int256 assetCashInternal = ar.convertFromUnderlying(vaultState.totalfCash)
            .add(vaultState.totalAssetCash.toInt())
            .neg();

        Token memory assetToken = TokenHandler.getAssetToken(vaultConfig.borrowCurrencyId);
        // If the asset token is NonMintable then the underlying is the same object.
        assetCashRequiredToSettle = assetToken.convertToExternal(assetCashInternal);

        if (assetToken.tokenType == TokenType.NonMintable) {
            // In this case both values are the same, there is no underlying token
            underlyingCashRequiredToSettle = assetCashRequiredToSettle;
        } else {
            Token memory underlyingToken = TokenHandler.getUnderlyingToken(vaultConfig.borrowCurrencyId);
            underlyingCashRequiredToSettle = underlyingToken.convertToUnderlyingExternalWithAdjustment(
                ar.convertToUnderlying(assetCashInternal)
            );
        }
    }

    function getLibInfo() external pure returns (address) {
        return address(TradingAction);
    }
}