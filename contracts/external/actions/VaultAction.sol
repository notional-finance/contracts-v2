// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    VaultState,
    VaultConfig,
    VaultConfigStorage,
    VaultStateStorage,
    VaultBorrowCapacityStorage,
    VaultAccount,
    Token,
    PrimeRate
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {PrimeRateLib} from "../../internal/pCash/PrimeRateLib.sol";
import {PrimeCashExchangeRate} from "../../internal/pCash/PrimeCashExchangeRate.sol";
import {TokenHandler} from "../../internal/balances/TokenHandler.sol";
import {VaultConfiguration} from "../../internal/vaults/VaultConfiguration.sol";
import {VaultAccountLib} from "../../internal/vaults/VaultAccount.sol";
import {VaultStateLib} from "../../internal/vaults/VaultState.sol";
import {VaultSecondaryBorrow} from "../../internal/vaults/VaultSecondaryBorrow.sol";

import {IVaultAction, IVaultAccountHealth} from "../../../interfaces/notional/IVaultController.sol";
import {ActionGuards} from "./ActionGuards.sol";
import {TradingAction} from "./TradingAction.sol";

contract VaultAction is ActionGuards, IVaultAction {
    using VaultConfiguration for VaultConfig;
    using VaultAccountLib for VaultAccount;
    using VaultStateLib for VaultState;
    using PrimeRateLib for PrimeRate;
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
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(secondaryCurrencyId);
        require(!underlyingToken.hasTransferFee); 

        // The secondary borrow currency must be white listed on the configuration before we can set a max
        // capacity.
        require(
            secondaryCurrencyId == vaultConfig.secondaryBorrowCurrencies[0] ||
            secondaryCurrencyId == vaultConfig.secondaryBorrowCurrencies[1]
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

    /// @notice Allows a vault to borrow a secondary currency if it is whitelisted to do so
    /// @param account account that is borrowing the secondary currency
    /// @param maturity the maturity to borrow at
    /// @param underlyingToBorrow fCash to borrow for the first and second secondary currencies
    /// @param maxBorrowRate maximum borrow rate for the first and second secondary currencies
    /// @param minRollLendRate max roll lend rate for the first and second borrow currencies
    /// @return underlyingTokensTransferred amount of tokens transferred back to the vault
    function borrowSecondaryCurrencyToVault(
        address account,
        uint256 maturity,
        uint256[2] calldata underlyingToBorrow,
        uint32[2] calldata maxBorrowRate,
        uint32[2] calldata minRollLendRate
    ) external override returns (int256[2] memory underlyingTokensTransferred) {
        // This method call must come from the vault
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(msg.sender);
        // This also ensures that the caller is an actual vault
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED));
        // Vaults cannot initiate borrows for themselves
        require(account != msg.sender);
        require(vaultConfig.hasSecondaryBorrows());

        PrimeRate[2] memory pr = VaultSecondaryBorrow.getSecondaryPrimeRateStateful(vaultConfig);
        (
            uint256 accountMaturity,
            int256 accountDebtOne,
            int256 accountDebtTwo
        ) = VaultSecondaryBorrow.getAccountSecondaryDebt(vaultConfig, account, pr);
        
        int256 netPrimeCashOne;
        int256 netPrimeCashTwo;
        // If the borrower is rolling their primary debt forward, we need to check that here and roll
        // their secondary debt forward in the same manner (simulate lending and then borrow more in
        // a longer dated maturity to repay their borrowing). Rolling debts forward can only occur if:
        //  - borrower has an existing debt position
        //  - borrower is rolling to a longer dated maturity
        //  - vault allows rolling positions forward
        if (
            accountMaturity != 0 &&
            accountMaturity != maturity &&
            vaultConfig.getFlag(VaultConfiguration.ALLOW_ROLL_POSITION)
        ) {
            // Lend to repay both debts if rolling
            (netPrimeCashOne, netPrimeCashTwo) = VaultSecondaryBorrow.executeSecondary(
                vaultConfig,
                account,
                accountMaturity,
                accountDebtOne.neg(),
                accountDebtTwo.neg(),
                pr,
                minRollLendRate
            );
        }

        (netPrimeCashOne, netPrimeCashTwo) = _borrowSecondary(
            vaultConfig, account, maturity, underlyingToBorrow, maxBorrowRate, netPrimeCashOne, netPrimeCashTwo, pr
        );
        require(netPrimeCashOne >= 0, "Insufficient Secondary Borrow");
        require(netPrimeCashTwo >= 0, "Insufficient Secondary Borrow");

        underlyingTokensTransferred[0] = _transferSecondary(
            msg.sender, vaultConfig.secondaryBorrowCurrencies[0], netPrimeCashOne, pr[0]
        );
        underlyingTokensTransferred[1] = _transferSecondary(
            msg.sender, vaultConfig.secondaryBorrowCurrencies[1], netPrimeCashTwo, pr[1]
        );
    }

    function _borrowSecondary(
        VaultConfig memory vaultConfig,
        address account,
        uint256 maturity,
        uint256[2] calldata underlyingToBorrow,
        uint32[2] calldata maxBorrowRate,
        int256 netPrimeCashOne,
        int256 netPrimeCashTwo,
        PrimeRate[2] memory pr
    ) private returns (int256, int256) {
        (int256 netPrimeBorrowedOne, int256 netPrimeBorrowedTwo) = VaultSecondaryBorrow.executeSecondary(
            vaultConfig,
            account,
            maturity,
            underlyingToBorrow[0].toInt().neg(),
            underlyingToBorrow[1].toInt().neg(),
            pr,
            maxBorrowRate
        );

        return (
            netPrimeCashOne.add(netPrimeBorrowedOne),
            netPrimeCashTwo.add(netPrimeBorrowedTwo)
        );
    }

    /// @notice Allows a vault to repay a secondary currency that it has borrowed. Will be executed via a callback
    /// which will request that the vault repay a specific amount of underlying tokens.
    /// @param account account that is repaying the secondary currency
    /// @param maturity the maturity to lend at
    /// @param underlyingToRepay amount of debt shares to repay (used to calculate fCashToLend)
    /// @param minLendRate minimum lend rate
    /// @return underlyingDepositExternal the amount of underlying transferred from the vault
    function repaySecondaryCurrencyFromVault(
        address account,
        uint256 maturity,
        uint256[2] calldata underlyingToRepay,
        uint32[2] calldata minLendRate
    ) external payable override returns (int256[2] memory underlyingDepositExternal) {
        // Vaults cannot repay borrows for themselves
        require(account != msg.sender);

        // This method call must come from the vault
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(msg.sender);
        require(vaultConfig.getFlag(VaultConfiguration.ENABLED));
        require(vaultConfig.hasSecondaryBorrows());

        PrimeRate[2] memory pr = VaultSecondaryBorrow.getSecondaryPrimeRateStateful(vaultConfig);
        // It is possible for netPrimeCash to be positive here, where the vault will receive tokens
        // as a result of "repayment"
        (int256 netPrimeCashOne, int256 netPrimeCashTwo) = VaultSecondaryBorrow.executeSecondary(
            vaultConfig,
            account,
            maturity,
            underlyingToRepay[0].toInt(),
            underlyingToRepay[1].toInt(),
            pr,
            minLendRate
        );

        underlyingDepositExternal[0] = _transferSecondary(
            msg.sender, vaultConfig.secondaryBorrowCurrencies[0], netPrimeCashOne, pr[0]
        );
        underlyingDepositExternal[1] = _transferSecondary(
            msg.sender, vaultConfig.secondaryBorrowCurrencies[1], netPrimeCashTwo, pr[1]
        );
    }

    function settleSecondaryBorrowForAccount(
        address vault,
        address account
    ) external override returns (bool didTransferSecondary) {
        // Only allow this to be called during settle vault account. Cannot be called directly.
        require(msg.sender == address(this)); // dev: unauthorized
        VaultConfig memory vaultConfig = VaultConfiguration.getVaultConfigStateful(vault);
        return VaultSecondaryBorrow.settleSecondaryBorrow(vaultConfig, account);
    }

    function _transferSecondary(
        address vault,
        uint16 currencyId,
        int256 netPrimeCash,
        PrimeRate memory pr
    ) private returns (int256 underlyingTokensTransferred) {
        // TODO: need to emit a mint / transfer / burn on the secondary if any excess is returned
        // to the vault account
        // TODO: consider switching all vault secondary borrow interactions to WETH

        // ETH transfers to the vault are always in native ETH, not wrapped
        if (netPrimeCash > 0) {
            underlyingTokensTransferred = VaultConfiguration.transferFromNotional(
                vault, currencyId, netPrimeCash, pr, false
            ).toInt().neg();
        } else {
            underlyingTokensTransferred = TokenHandler.depositExactToMintPrimeCash(
                vault, currencyId, netPrimeCash.neg(), pr, false
            );
        }
    }


    function getLibInfo() external pure returns (address) {
        return address(TradingAction);
    }
}