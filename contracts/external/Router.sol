// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./actions/nTokenAction.sol";
import "./actions/nTokenMintAction.sol";
import "../actions/GovernanceAction.sol";
import "../actions/RedeemPerpetualTokenAction.sol";
import "../actions/DepositWithdrawAction.sol";
import "../actions/InitializeMarketsAction.sol";
import "../storage/StorageLayoutV1.sol";
import "../storage/TokenHandler.sol";
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
    address public immutable DEPOSIT_WITHDRAW_ACTION;
    address public immutable cETH;

    constructor(
        address governance_,
        address views_,
        address initializeMarket_,
        address nTokenActions_,
        address nTokenRedeem_,
        address depositWithdrawAction_,
        address cETH_
    ) {
        GOVERNANCE = governance_;
        VIEWS = views_;
        INITIALIZE_MARKET = initializeMarket_;
        NTOKEN_ACTIONS = nTokenActions_;
        NTOKEN_REDEEM = nTokenRedeem_;
        DEPOSIT_WITHDRAW_ACTION = depositWithdrawAction_;
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

    /**
     * @notice Returns the implementation contract for the method signature
     */
    function getRouterImplementation(bytes4 sig) public view returns (address) {
        if (
            // TODO: move these to their own contract?
            sig == DepositWithdrawAction.depositUnderlyingToken.selector ||
            sig == DepositWithdrawAction.depositAssetToken.selector ||
            sig == DepositWithdrawAction.withdraw.selector ||
            sig == DepositWithdrawAction.settleAccount.selector ||
            // TODO: move these to their own contract?
            sig == DepositWithdrawAction.batchBalanceAction.selector ||
            sig == DepositWithdrawAction.batchBalanceAndTradeAction.selector
        ) {
            return DEPOSIT_WITHDRAW_ACTION;
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
            sig == RedeemPerpetualTokenAction.perpetualTokenRedeem.selector ||
            sig == RedeemPerpetualTokenAction.perpetualTokenRedeemViaBatch.selector
        ) {
            return NTOKEN_REDEEM;
        }

        if (sig == InitializeMarketsAction.initializeMarkets.selector) {
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
            sig == GovernanceAction.updatePerpetualDepositParameters.selector ||
            sig == GovernanceAction.updateInitializationParameters.selector ||
            sig == GovernanceAction.updatePerpetualTokenCollateralParameters.selector
        ) {
            return GOVERNANCE;
        }

        // If not found then delegate to views. This will revert if there is no method on
        // the view contract
        return VIEWS;
    }

    /**
     * @dev Delegates the current call to `implementation`.
     *
     * This function does not return to its internal call site, it will return directly to the external caller.
     */
    function _delegate(address implementation) internal {
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
