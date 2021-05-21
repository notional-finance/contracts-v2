// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./actions/AccountAction.sol";
import "./actions/BatchAction.sol";
import "./actions/nTokenAction.sol";
import "./actions/nTokenMintAction.sol";
import "./actions/nTokenRedeemAction.sol";
import "./actions/GovernanceAction.sol";
import "./actions/InitializeMarketsAction.sol";
import "./actions/ERC1155Action.sol";
import "./actions/LiquidatefCashAction.sol";
import "./actions/LiquidateCurrencyAction.sol";
import "../global/StorageLayoutV1.sol";
import "../global/Types.sol";
import "@openzeppelin/contracts/proxy/TransparentUpgradeableProxy.sol";

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
    address public immutable NTOKEN_REDEEM;
    address public immutable BATCH_ACTION;
    address public immutable ACCOUNT_ACTION;
    address public immutable ERC1155;
    address public immutable LIQUIDATE_CURRENCY;
    address public immutable LIQUIDATE_FCASH;
    address public immutable cETH;

    constructor(
        address governance_,
        address views_,
        address initializeMarket_,
        address nTokenActions_,
        address nTokenRedeem_,
        address batchAction_,
        address accountAction_,
        address erc1155_,
        address liquidateCurrency_,
        address liquidatefCash_,
        address cETH_
    ) {
        GOVERNANCE = governance_;
        VIEWS = views_;
        INITIALIZE_MARKET = initializeMarket_;
        NTOKEN_ACTIONS = nTokenActions_;
        NTOKEN_REDEEM = nTokenRedeem_;
        BATCH_ACTION = batchAction_;
        ACCOUNT_ACTION = accountAction_;
        ERC1155 = erc1155_;
        LIQUIDATE_CURRENCY = liquidateCurrency_;
        LIQUIDATE_FCASH = liquidatefCash_;
        cETH = cETH_;
    }

    function initialize(address owner_) public {
        // Cannot re-initialize once the contract has been initialized, ownership transfer does not
        // allow address to be set back to zero
        require(owner == address(0), "R: already initialized");

        // Allow list currency to be called by this contract for the purposes of
        // initializing ETH as a currency
        owner = msg.sender;
        // List ETH as currency id == 1, NOTE: return value is ignored here
        (bool status, ) =
            address(GOVERNANCE).delegatecall(
                abi.encodeWithSelector(
                    GovernanceAction.listCurrency.selector,
                    TokenStorage(cETH, false, TokenType.cETH),
                    // No underlying set for cETH
                    TokenStorage(address(0), false, TokenType.Ether),
                    address(0),
                    false,
                    140,
                    100,
                    106
                )
            );
        require(status);

        owner = owner_;
    }

    /// @notice Returns the implementation contract for the method signature
    /// @param sig method signature to call
    /// @return implementation address
    function getRouterImplementation(bytes4 sig) public view returns (address) {
        if (
            sig == BatchAction.batchBalanceAction.selector ||
            sig == BatchAction.batchBalanceAndTradeAction.selector
        ) {
            return BATCH_ACTION;
        }

        if (
            sig == nTokenAction.nTokenTotalSupply.selector ||
            sig == nTokenAction.nTokenBalanceOf.selector ||
            sig == nTokenAction.nTokenTransferAllowance.selector ||
            sig == nTokenAction.nTokenTransferApprove.selector ||
            sig == nTokenAction.nTokenTransfer.selector ||
            sig == nTokenAction.nTokenTransferFrom.selector ||
            sig == nTokenAction.nTokenClaimIncentives.selector ||
            sig == nTokenAction.nTokenGetClaimableIncentives.selector ||
            sig == nTokenAction.nTokenTransferApproveAll.selector ||
            sig == nTokenAction.nTokenPresentValueAssetDenominated.selector ||
            sig == nTokenAction.nTokenPresentValueUnderlyingDenominated.selector
        ) {
            return NTOKEN_ACTIONS;
        }

        if (
            sig == AccountAction.depositUnderlyingToken.selector ||
            sig == AccountAction.depositAssetToken.selector ||
            sig == AccountAction.withdraw.selector ||
            sig == AccountAction.settleAccount.selector ||
            sig == AccountAction.enableBitmapCurrency.selector
        ) {
            return ACCOUNT_ACTION;
        }

        if (
            sig == nTokenRedeemAction.nTokenRedeem.selector ||
            sig == nTokenRedeemAction.nTokenRedeemViaBatch.selector
        ) {
            return NTOKEN_REDEEM;
        }

        if (
            sig == ERC1155Action.supportsInterface.selector ||
            sig == ERC1155Action.balanceOf.selector ||
            sig == ERC1155Action.balanceOfBatch.selector ||
            sig == ERC1155Action.safeTransferFrom.selector ||
            sig == ERC1155Action.safeBatchTransferFrom.selector ||
            sig == ERC1155Action.decodeToAssets.selector ||
            sig == ERC1155Action.encodeToId.selector ||
            sig == ERC1155Action.setApprovalForAll.selector ||
            sig == ERC1155Action.isApprovedForAll.selector
        ) {
            return ERC1155;
        }

        if (
            sig == LiquidateCurrencyAction.liquidateLocalCurrency.selector ||
            sig == LiquidateCurrencyAction.liquidateCollateralCurrency.selector ||
            sig == LiquidateCurrencyAction.calculateLocalCurrencyLiquidation.selector ||
            sig == LiquidateCurrencyAction.calculateCollateralCurrencyLiquidation.selector
        ) {
            return LIQUIDATE_CURRENCY;
        }

        if (
            sig == LiquidatefCashAction.liquidatefCashLocal.selector ||
            sig == LiquidatefCashAction.liquidatefCashCrossCurrency.selector ||
            sig == LiquidatefCashAction.calculatefCashLocalLiquidation.selector ||
            sig == LiquidatefCashAction.calculatefCashCrossCurrencyLiquidation.selector
        ) {
            return LIQUIDATE_FCASH;
        }

        if (
            sig == InitializeMarketsAction.initializeMarkets.selector ||
            sig == InitializeMarketsAction.sweepCashIntoMarkets.selector
        ) {
            return INITIALIZE_MARKET;
        }

        if (
            sig == GovernanceAction.listCurrency.selector ||
            sig == GovernanceAction.enableCashGroup.selector ||
            sig == GovernanceAction.updateCashGroup.selector ||
            sig == GovernanceAction.updateAssetRate.selector ||
            sig == GovernanceAction.updateETHRate.selector ||
            sig == GovernanceAction.transferOwnership.selector ||
            sig == GovernanceAction.updateIncentiveEmissionRate.selector ||
            sig == GovernanceAction.updateDepositParameters.selector ||
            sig == GovernanceAction.updateInitializationParameters.selector ||
            sig == GovernanceAction.updateTokenCollateralParameters.selector ||
            sig == GovernanceAction.updateGlobalTransferOperator.selector
        ) {
            return GOVERNANCE;
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

    // NOTE: receive() is overridden in "nTransparentUpgradeableProxy" to allow for eth transfers to succeed
    // with limited gas so that is the contract that must be deployed, not the regular OZ proxy.
}

contract nTransparentUpgradeableProxy is TransparentUpgradeableProxy {
    constructor(
        address _logic,
        address admin_,
        bytes memory _data
    ) TransparentUpgradeableProxy(_logic, admin_, _data) {}

    receive() external payable override {}
}
