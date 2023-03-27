// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "./actions/nTokenMintAction.sol";
import "../global/StorageLayoutV1.sol";
import "../global/Types.sol";
import {nTokenERC20} from "../../interfaces/notional/nTokenERC20.sol";
import "../../interfaces/notional/NotionalProxy.sol";
import {nERC1155Interface} from "../../interfaces/notional/nERC1155Interface.sol";
import {NotionalGovernance} from "../../interfaces/notional/NotionalGovernance.sol";
import {NotionalCalculations} from "../../interfaces/notional/NotionalCalculations.sol";
import {
    IVaultAction,
    IVaultAccountAction,
    IVaultLiquidationAction,
    IVaultAccountHealth
} from "../../interfaces/notional/IVaultController.sol";

/**
 * @notice Sits behind an upgradeable proxy and routes methods to an appropriate implementation contract. All storage
 * will sit inside the upgradeable proxy and this router will authorize the call and re-route the calls to implementing
 * contracts.
 *
 * This pattern adds an additional hop between the proxy and the ultimate implementation contract, however, it also
 * allows for atomic upgrades of the entire system. Individual implementation contracts will be deployed and then a
 * new Router with the new hardcoded addresses will then be deployed and upgraded into place.
 */
contract Router is StorageLayoutV1 {
    // These contract addresses cannot be changed once set by the constructor
    address public immutable GOVERNANCE;
    address public immutable VIEWS;
    address public immutable INITIALIZE_MARKET;
    address public immutable NTOKEN_ACTIONS;
    address public immutable BATCH_ACTION;
    address public immutable ACCOUNT_ACTION;
    address public immutable ERC1155;
    address public immutable LIQUIDATE_CURRENCY;
    address public immutable LIQUIDATE_FCASH;
    address public immutable TREASURY;
    address public immutable CALCULATION_VIEWS;
    address public immutable VAULT_ACCOUNT_ACTION;
    address public immutable VAULT_ACTION;
    address public immutable VAULT_LIQUIDATION_ACTION;
    address public immutable VAULT_ACCOUNT_HEALTH;
    address private immutable DEPLOYER;

    struct DeployedContracts {
        address governance;
        address views;
        address initializeMarket;
        address nTokenActions;
        address batchAction;
        address accountAction;
        address erc1155;
        address liquidateCurrency;
        address liquidatefCash;
        address treasury;
        address calculationViews;
        address vaultAccountAction;
        address vaultAction;
        address vaultLiquidationAction;
        address vaultAccountHealth;
    }

    constructor(
        DeployedContracts memory contracts
    ) {
        GOVERNANCE = contracts.governance;
        VIEWS = contracts.views;
        INITIALIZE_MARKET = contracts.initializeMarket;
        NTOKEN_ACTIONS = contracts.nTokenActions;
        BATCH_ACTION = contracts.batchAction;
        ACCOUNT_ACTION = contracts.accountAction;
        ERC1155 = contracts.erc1155;
        LIQUIDATE_CURRENCY = contracts.liquidateCurrency;
        LIQUIDATE_FCASH = contracts.liquidatefCash;
        TREASURY = contracts.treasury;
        CALCULATION_VIEWS = contracts.calculationViews;
        VAULT_ACCOUNT_ACTION = contracts.vaultAccountAction;
        VAULT_ACTION = contracts.vaultAction;
        VAULT_LIQUIDATION_ACTION = contracts.vaultLiquidationAction;
        VAULT_ACCOUNT_HEALTH = contracts.vaultAccountHealth;

        DEPLOYER = msg.sender;
        // This will lock everyone from calling initialize on the implementation contract
        hasInitialized = true;
    }

    function initialize(address owner_, address pauseRouter_, address pauseGuardian_) public {
        // Check that only the deployer can initialize
        require(msg.sender == DEPLOYER && !hasInitialized);

        owner = owner_;
        // The pause guardian may downgrade the router to the pauseRouter
        pauseRouter = pauseRouter_;
        pauseGuardian = pauseGuardian_;

        hasInitialized = true;
    }

    /// @notice Returns the implementation contract for the method signature
    /// @param sig method signature to call
    /// @return implementation address
    function getRouterImplementation(bytes4 sig) public view returns (address) {
        if (
            sig == NotionalProxy.batchBalanceAction.selector ||
            sig == NotionalProxy.batchBalanceAndTradeAction.selector ||
            sig == NotionalProxy.batchBalanceAndTradeActionWithCallback.selector ||
            sig == NotionalProxy.batchLend.selector
        ) {
            return BATCH_ACTION;
        } else if (
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
            sig == IVaultAccountAction.enterVault.selector ||
            sig == IVaultAccountAction.rollVaultPosition.selector ||
            sig == IVaultAccountAction.exitVault.selector ||
            sig == IVaultAccountAction.settleVaultAccount.selector
        ) {
            return VAULT_ACCOUNT_ACTION;
        } else if (
            sig == NotionalProxy.depositUnderlyingToken.selector ||
            sig == NotionalProxy.depositAssetToken.selector ||
            sig == NotionalProxy.withdraw.selector ||
            sig == NotionalProxy.settleAccount.selector ||
            sig == NotionalProxy.nTokenRedeem.selector ||
            sig == NotionalProxy.enableBitmapCurrency.selector ||
            sig == NotionalProxy.enablePrimeBorrow.selector
        ) {
            return ACCOUNT_ACTION;
        } else if (
            sig == nERC1155Interface.supportsInterface.selector ||
            sig == nERC1155Interface.balanceOf.selector ||
            sig == nERC1155Interface.balanceOfBatch.selector ||
            sig == nERC1155Interface.signedBalanceOf.selector ||
            sig == nERC1155Interface.signedBalanceOfBatch.selector ||
            sig == nERC1155Interface.safeTransferFrom.selector ||
            sig == nERC1155Interface.safeBatchTransferFrom.selector ||
            sig == nERC1155Interface.decodeToAssets.selector ||
            sig == nERC1155Interface.encodeToId.selector ||
            sig == nERC1155Interface.setApprovalForAll.selector ||
            sig == nERC1155Interface.isApprovedForAll.selector
        ) {
            return ERC1155;
        } else if (
            sig == nTokenERC20.nTokenTotalSupply.selector ||
            sig == nTokenERC20.nTokenBalanceOf.selector ||
            sig == nTokenERC20.nTokenTransferAllowance.selector ||
            sig == nTokenERC20.nTokenTransferApprove.selector ||
            sig == nTokenERC20.nTokenTransfer.selector ||
            sig == nTokenERC20.nTokenTransferFrom.selector ||
            sig == nTokenERC20.nTokenTransferApproveAll.selector ||
            sig == nTokenERC20.nTokenClaimIncentives.selector ||
            sig == nTokenERC20.pCashTransferAllowance.selector ||
            sig == nTokenERC20.pCashTransferApprove.selector ||
            sig == nTokenERC20.pCashTransfer.selector ||
            sig == nTokenERC20.pCashTransferFrom.selector
        ) {
            return NTOKEN_ACTIONS;
        } else if (
            sig == NotionalProxy.liquidateLocalCurrency.selector ||
            sig == NotionalProxy.liquidateCollateralCurrency.selector ||
            sig == NotionalProxy.calculateLocalCurrencyLiquidation.selector ||
            sig == NotionalProxy.calculateCollateralCurrencyLiquidation.selector
        ) {
            return LIQUIDATE_CURRENCY;
        } else if (
            sig == NotionalProxy.liquidatefCashLocal.selector ||
            sig == NotionalProxy.liquidatefCashCrossCurrency.selector ||
            sig == NotionalProxy.calculatefCashLocalLiquidation.selector ||
            sig == NotionalProxy.calculatefCashCrossCurrencyLiquidation.selector
        ) {
            return LIQUIDATE_FCASH;
        } else if (
            sig == IVaultLiquidationAction.deleverageAccount.selector ||
            sig == IVaultLiquidationAction.liquidateVaultCashBalance.selector
        ) {
            return VAULT_LIQUIDATION_ACTION;
        } else if (
            sig == IVaultAction.updateVault.selector ||
            sig == IVaultAction.setVaultPauseStatus.selector ||
            sig == IVaultAction.setVaultDeleverageStatus.selector ||
            sig == IVaultAction.setMaxBorrowCapacity.selector ||
            sig == IVaultAction.updateSecondaryBorrowCapacity.selector ||
            sig == IVaultAction.borrowSecondaryCurrencyToVault.selector ||
            sig == IVaultAction.repaySecondaryCurrencyFromVault.selector ||
            sig == IVaultAction.settleSecondaryBorrowForAccount.selector
        ) {
            return VAULT_ACTION;
        } else if (
            sig == NotionalProxy.initializeMarkets.selector ||
            sig == NotionalProxy.sweepCashIntoMarkets.selector
        ) {
            return INITIALIZE_MARKET;
        } else if (
            sig == NotionalGovernance.listCurrency.selector ||
            sig == NotionalGovernance.enableCashGroup.selector ||
            sig == NotionalGovernance.setMaxUnderlyingSupply.selector ||
            sig == NotionalGovernance.setPauseRouterAndGuardian.selector ||
            sig == NotionalGovernance.updatePrimeCashHoldingsOracle.selector ||
            sig == NotionalGovernance.updatePrimeCashCurve.selector ||
            sig == NotionalGovernance.enablePrimeDebt.selector ||
            sig == NotionalGovernance.updateCashGroup.selector ||
            sig == NotionalGovernance.updateETHRate.selector ||
            sig == NotionalGovernance.transferOwnership.selector ||
            sig == NotionalGovernance.claimOwnership.selector ||
            sig == NotionalGovernance.updateInterestRateCurve.selector ||
            sig == NotionalGovernance.updateDepositParameters.selector ||
            sig == NotionalGovernance.updateInitializationParameters.selector ||
            sig == NotionalGovernance.updateTokenCollateralParameters.selector ||
            sig == NotionalGovernance.updateAuthorizedCallbackContract.selector ||
            sig == NotionalGovernance.upgradeBeacon.selector ||
            sig == NotionalProxy.upgradeTo.selector ||
            sig == NotionalProxy.upgradeToAndCall.selector
        ) {
            return GOVERNANCE;
        } else if (
            sig == NotionalTreasury.updateIncentiveEmissionRate.selector ||
            sig == NotionalTreasury.claimCOMPAndTransfer.selector ||
            sig == NotionalTreasury.transferReserveToTreasury.selector ||
            sig == NotionalTreasury.setTreasuryManager.selector ||
            sig == NotionalTreasury.setReserveBuffer.selector ||
            sig == NotionalTreasury.setReserveCashBalance.selector ||
            sig == NotionalTreasury.setRebalancingTargets.selector ||
            sig == NotionalTreasury.setRebalancingCooldown.selector ||
            sig == NotionalTreasury.rebalance.selector
        ) {
            return TREASURY;
        } else if (
            sig == NotionalCalculations.calculateNTokensToMint.selector ||
            sig == NotionalCalculations.nTokenPresentValueAssetDenominated.selector ||
            sig == NotionalCalculations.nTokenPresentValueUnderlyingDenominated.selector ||
            sig == NotionalCalculations.getfCashAmountGivenCashAmount.selector ||
            sig == NotionalCalculations.getCashAmountGivenfCashAmount.selector ||
            sig == NotionalCalculations.nTokenGetClaimableIncentives.selector ||
            sig == NotionalCalculations.getPresentfCashValue.selector ||
            sig == NotionalCalculations.getMarketIndex.selector ||
            sig == NotionalCalculations.getfCashLendFromDeposit.selector ||
            sig == NotionalCalculations.getfCashBorrowFromPrincipal.selector ||
            sig == NotionalCalculations.getDepositFromfCashLend.selector ||
            sig == NotionalCalculations.getPrincipalFromfCashBorrow.selector ||
            sig == NotionalCalculations.convertCashBalanceToExternal.selector ||
            sig == NotionalCalculations.convertSettledfCash.selector ||
            sig == NotionalCalculations.convertUnderlyingToPrimeCash.selector ||
            sig == NotionalCalculations.accruePrimeInterest.selector
        ) {
            return CALCULATION_VIEWS;
        } else {
            // If not found then delegate to views. This will revert if there is no method on
            // the view contract
            return VIEWS;
        }
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

    // NOTE: receive() is overridden in "nProxy" to allow for eth transfers to succeed
    receive() external payable { }
}
