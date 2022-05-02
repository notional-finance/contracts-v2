// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./actions/nTokenAction.sol";
import "./actions/nTokenMintAction.sol";
import "../global/StorageLayoutV1.sol";
import "../global/Types.sol";
import "../../interfaces/notional/NotionalProxy.sol";
import "../../interfaces/notional/nERC1155Interface.sol";
import "../../interfaces/notional/NotionalGovernance.sol";
import "../../interfaces/notional/NotionalCalculations.sol";

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
    address public immutable cETH;
    address public immutable TREASURY;
    address public immutable CALCULATION_VIEWS;
    address private immutable DEPLOYER;

    constructor(
        address governance_,
        address views_,
        address initializeMarket_,
        address nTokenActions_,
        address batchAction_,
        address accountAction_,
        address erc1155_,
        address liquidateCurrency_,
        address liquidatefCash_,
        address cETH_,
        address treasury_,
        address calculationViews_
    ) {
        GOVERNANCE = governance_;
        VIEWS = views_;
        INITIALIZE_MARKET = initializeMarket_;
        NTOKEN_ACTIONS = nTokenActions_;
        BATCH_ACTION = batchAction_;
        ACCOUNT_ACTION = accountAction_;
        ERC1155 = erc1155_;
        LIQUIDATE_CURRENCY = liquidateCurrency_;
        LIQUIDATE_FCASH = liquidatefCash_;
        cETH = cETH_;
        DEPLOYER = msg.sender;
        TREASURY = treasury_;
        CALCULATION_VIEWS = calculationViews_;

        // This will lock everyone from calling initialize on the implementation contract
        hasInitialized = true;
    }

    function initialize(address owner_, address pauseRouter_, address pauseGuardian_) public {
        // Check that only the deployer can initialize
        require(msg.sender == DEPLOYER && !hasInitialized);

        // Allow list currency to be called by this contract for the purposes of
        // initializing ETH as a currency
        owner = msg.sender;
        // List ETH as currency id == 1, NOTE: return value is ignored here

        // FIXME: on non-mainnet deployments we should be using WETH instead here...
        (bool status, ) =
            address(GOVERNANCE).delegatecall(
                abi.encodeWithSelector(
                    NotionalGovernance.listCurrency.selector,
                    TokenStorage(cETH, false, TokenType.cETH, Constants.CETH_DECIMAL_PLACES, 0),
                    // No underlying set for cETH
                    TokenStorage(address(0), false, TokenType.Ether, Constants.ETH_DECIMAL_PLACES, 0),
                    address(0),
                    false,
                    133, // Initial settings of 133% buffer
                    75,  // 75% haircut
                    108  // 8% liquidation discount
                )
            );
        require(status);

        owner = owner_;
        // The pause guardian may downgrade the router to the pauseRouter
        pauseRouter = pauseRouter_;
        pauseGuardian = pauseGuardian_;

        hasInitialized == true;
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
            sig == nTokenAction.nTokenTotalSupply.selector ||
            sig == nTokenAction.nTokenBalanceOf.selector ||
            sig == nTokenAction.nTokenTransferAllowance.selector ||
            sig == nTokenAction.nTokenTransferApprove.selector ||
            sig == nTokenAction.nTokenTransfer.selector ||
            sig == nTokenAction.nTokenTransferFrom.selector ||
            sig == nTokenAction.nTokenClaimIncentives.selector ||
            sig == nTokenAction.nTokenTransferApproveAll.selector ||
            sig == nTokenAction.nTokenPresentValueAssetDenominated.selector ||
            sig == nTokenAction.nTokenPresentValueUnderlyingDenominated.selector
        ) {
            return NTOKEN_ACTIONS;
        } else if (
            sig == NotionalProxy.depositUnderlyingToken.selector ||
            sig == NotionalProxy.depositAssetToken.selector ||
            sig == NotionalProxy.withdraw.selector ||
            sig == NotionalProxy.settleAccount.selector ||
            sig == NotionalProxy.nTokenRedeem.selector ||
            sig == NotionalProxy.enableBitmapCurrency.selector
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
            sig == NotionalProxy.initializeMarkets.selector ||
            sig == NotionalProxy.sweepCashIntoMarkets.selector
        ) {
            return INITIALIZE_MARKET;
        } else if (
            sig == NotionalGovernance.listCurrency.selector ||
            sig == NotionalGovernance.enableCashGroup.selector ||
            sig == NotionalGovernance.updateCashGroup.selector ||
            sig == NotionalGovernance.updateAssetRate.selector ||
            sig == NotionalGovernance.updateETHRate.selector ||
            sig == NotionalGovernance.transferOwnership.selector ||
            sig == NotionalGovernance.claimOwnership.selector ||
            sig == NotionalGovernance.updateIncentiveEmissionRate.selector ||
            sig == NotionalGovernance.updateMaxCollateralBalance.selector ||
            sig == NotionalGovernance.updateDepositParameters.selector ||
            sig == NotionalGovernance.updateInitializationParameters.selector ||
            sig == NotionalGovernance.updateTokenCollateralParameters.selector ||
            sig == NotionalGovernance.updateGlobalTransferOperator.selector ||
            sig == NotionalGovernance.updateAuthorizedCallbackContract.selector ||
            sig == NotionalGovernance.setLendingPool.selector ||
            sig == NotionalProxy.upgradeTo.selector ||
            sig == NotionalProxy.upgradeToAndCall.selector
        ) {
            return GOVERNANCE;
        } else if (
            sig == NotionalTreasury.claimCOMPAndTransfer.selector ||
            sig == NotionalTreasury.transferReserveToTreasury.selector ||
            sig == NotionalTreasury.setTreasuryManager.selector ||
            sig == NotionalTreasury.setReserveBuffer.selector ||
            sig == NotionalTreasury.setReserveCashBalance.selector
        ) {
            return TREASURY;
        } else if (
            sig == NotionalCalculations.calculateNTokensToMint.selector ||
            sig == NotionalCalculations.getfCashAmountGivenCashAmount.selector ||
            sig == NotionalCalculations.getCashAmountGivenfCashAmount.selector ||
            sig == NotionalCalculations.nTokenGetClaimableIncentives.selector ||
            sig == NotionalCalculations.getPresentfCashValue.selector ||
            sig == NotionalCalculations.getMarketIndex.selector ||
            sig == NotionalCalculations.getfCashLendFromDeposit.selector ||
            sig == NotionalCalculations.getfCashBorrowFromPrincipal.selector ||
            sig == NotionalCalculations.getDepositFromfCashLend.selector ||
            sig == NotionalCalculations.getPrincipalFromfCashBorrow.selector ||
            sig == NotionalCalculations.convertCashBalanceToExternal.selector
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
}
