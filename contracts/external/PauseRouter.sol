// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./actions/ActionGuards.sol";
import "../global/StorageLayoutV2.sol";
import "../global/Constants.sol";
import "../proxy/utils/UUPSUpgradeable.sol";
import "../../interfaces/notional/NotionalProxy.sol";
import "../../interfaces/notional/NotionalCalculations.sol";
import {IVaultAccountHealth} from "../../interfaces/notional/IVaultController.sol";

/**
 * Read only version of the Router that can only be upgraded by governance. Used in emergency when the system must
 * be paused for some reason.
 */
contract PauseRouter is StorageLayoutV2, UUPSUpgradeable, ActionGuards {
    address public immutable VIEWS;
    address public immutable LIQUIDATE_CURRENCY;
    address public immutable LIQUIDATE_FCASH;
    address public immutable CALCULATION_VIEWS;
    address public immutable VAULT_ACCOUNT_HEALTH;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(
        address views_,
        address liquidateCurrency_,
        address liquidatefCash_,
        address calculationViews_,
        address vaultAccountHealth_
    ) {
        VIEWS = views_;
        LIQUIDATE_CURRENCY = liquidateCurrency_;
        LIQUIDATE_FCASH = liquidatefCash_;
        CALCULATION_VIEWS = calculationViews_;
        VAULT_ACCOUNT_HEALTH = vaultAccountHealth_;
    }

    /// @dev Internal method will be called during an UUPS upgrade, must return true to
    /// authorize the upgrade. The UUPS check does a rollback check during the upgrade and
    /// therefore we use the `rollbackRouterImplementation` to authorize the pauseGuardian
    /// during this check. See GovernanceAction._authorizeUpgrade for where the rollbackRouterImplementation
    /// storage slot is set.
    function _authorizeUpgrade(address newImplementation) internal override {
        // This is only true during a rollback check when the pause router is downgraded
        bool isRollbackCheck = rollbackRouterImplementation != address(0) &&
            newImplementation == rollbackRouterImplementation;

        require(
            owner == msg.sender || (msg.sender == pauseGuardian && isRollbackCheck),
            "Unauthorized upgrade"
        );

        // Clear this storage slot so the guardian cannot upgrade back to the previous router,
        // requires governance to do so.
        rollbackRouterImplementation = address(0);
    }

    /// @notice Transfers ownership to `newOwner`. Either directly or claimable by the new pending owner.
    /// Can only be invoked by the current `owner`.
    /// @param newOwner Address of the new owner.
    /// @param direct True if `newOwner` should be set immediately. False if `newOwner` needs to use `claimOwnership`.
    function transferOwnership(
        address newOwner,
        bool direct
    ) external onlyOwner {
        if (direct) {
            // Checks
            require(newOwner != address(0), "Ownable: zero address");

            // Effects
            emit OwnershipTransferred(owner, newOwner);
            owner = newOwner;
            pendingOwner = address(0);
        } else {
            // Effects
            pendingOwner = newOwner;
        }
    }

    function claimOwnership() external {
        address _pendingOwner = pendingOwner;

        // Checks
        require(msg.sender == _pendingOwner, "Ownable: caller != pending owner");

        // Effects
        emit OwnershipTransferred(owner, _pendingOwner);
        owner = _pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice Shows the current state of which liquidations are enabled
    /// @return the current liquidation enable state as a bitmap
    function getLiquidationEnabledState() external view returns (bytes1) {
        return liquidationEnabledState;
    }

    /// @notice Sets a new liquidation enable state, only the owner or the guardian may do so
    function setLiquidationEnabledState(bytes1 liquidationEnabledState_) external {
        // Only authorized addresses can set the liquidation state
        require(owner == msg.sender || msg.sender == pauseGuardian);
        liquidationEnabledState = liquidationEnabledState_;
    }

    function isEnabled(bytes1 state) private view returns (bool) {
        return (liquidationEnabledState & state == state);
    }

    function getRouterImplementation(bytes4 sig) public view returns (address) {
        // Liquidation calculation methods are stateful (they settle accounts if required)
        // and therefore we prevent them from being called unless specifically authorized.
        if (
            (sig == NotionalProxy.calculateCollateralCurrencyLiquidation.selector ||
                sig == NotionalProxy.liquidateCollateralCurrency.selector) &&
            isEnabled(Constants.COLLATERAL_CURRENCY_ENABLED)
        ) {
            return LIQUIDATE_CURRENCY;
        }

        if (
            (sig == NotionalProxy.calculateLocalCurrencyLiquidation.selector ||
                sig == NotionalProxy.liquidateLocalCurrency.selector) &&
            isEnabled(Constants.LOCAL_CURRENCY_ENABLED)
        ) {
            return LIQUIDATE_CURRENCY;
        }

        if (
            (sig == NotionalProxy.liquidatefCashLocal.selector ||
                sig == NotionalProxy.calculatefCashLocalLiquidation.selector) &&
            isEnabled(Constants.LOCAL_FCASH_ENABLED)
        ) {
            return LIQUIDATE_FCASH;
        }

        if (
            (sig == NotionalProxy.liquidatefCashCrossCurrency.selector ||
                sig == NotionalProxy.calculatefCashCrossCurrencyLiquidation.selector) &&
            isEnabled(Constants.CROSS_CURRENCY_FCASH_ENABLED)
        ) {
            return LIQUIDATE_FCASH;
        }

        if (
            sig == IVaultAccountHealth.getVaultAccountHealthFactors.selector ||
            sig == IVaultAccountHealth.calculateDepositAmountInDeleverage.selector ||
            sig == IVaultAccountHealth.checkVaultAccountCollateralRatio.selector ||
            sig == IVaultAccountHealth.signedBalanceOfVaultTokenId.selector ||
            sig == IVaultAccountHealth.getVaultAccount.selector ||
            sig == IVaultAccountHealth.getVaultConfig.selector ||
            sig == IVaultAccountHealth.getBorrowCapacity.selector ||
            sig == IVaultAccountHealth.getSecondaryBorrow.selector ||
            sig == IVaultAccountHealth.getVaultAccountSecondaryDebt.selector ||
            sig == IVaultAccountHealth.getVaultState.selector
        ) {
            return VAULT_ACCOUNT_HEALTH;
        } else if (
            sig == NotionalCalculations.calculateNTokensToMint.selector ||
            sig == NotionalCalculations.getfCashAmountGivenCashAmount.selector ||
            sig == NotionalCalculations.getCashAmountGivenfCashAmount.selector ||
            sig == NotionalCalculations.nTokenGetClaimableIncentives.selector
        ) {
            return CALCULATION_VIEWS;
        }

        // If not found then delegate to views. This will revert if there is no method on
        // the view contract
        return VIEWS;
    }

    /// @dev Delegates the current call to `implementation`.
    /// This function does not return to its internal call site, it will return directly to the external caller.
    function _delegate(address implementation) private {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Call the implementation.
            // out and outsize are 0 because we don't know the size yet.
            let result := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // delegatecall returns 0 on error.
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    fallback() external payable {
        _delegate(getRouterImplementation(msg.sig));
    }

    receive() external payable { }
}
