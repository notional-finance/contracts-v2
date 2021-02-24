// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/StorageLayoutV1.sol";
import "./GovernanceAction.sol";
import "./PerpetualTokenAction.sol";
import "./MintPerpetualTokenAction.sol";
import "./InitializeMarketsAction.sol";

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
    address public immutable PERPETUAL_TOKEN_ACTIONS;
    address public immutable PERPETUAL_TOKEN_MINT;
    address public immutable cETH;
    address public immutable WETH;

    constructor(
        address governance_,
        address views_,
        address initializeMarket_,
        address perpetualTokenActions_,
        address perpetualTokenMint_,
        address cETH_,
        address weth_
    ) {
        GOVERNANCE = governance_;
        VIEWS = views_;
        INITIALIZE_MARKET = initializeMarket_;
        PERPETUAL_TOKEN_ACTIONS = perpetualTokenActions_;
        PERPETUAL_TOKEN_MINT = perpetualTokenMint_;
        cETH = cETH_;
        WETH = weth_;
    }

    function initialize(address owner_) public {
        // Cannot re-initialize once the contract has been initialized
        require(owner == address(0), "R: already initialized");

        // Allow list currency to be called by this contract for the purposes of
        // initializing ETH as a currency
        owner = msg.sender;
        // List ETH as currency id == 1, NOTE: return value is ignored here
        address(GOVERNANCE).delegatecall(
            abi.encodeWithSelector(
                GovernanceAction.listCurrency.selector,
                cETH,
                false,
                address(0),
                false,
                140,
                100,
                106
            )
        );

        owner = owner_;
    }

    /**
     * @notice Returns the implementation contract for the method signature
     */
    function getRouterImplementation(bytes4 sig) public view returns (address) {
        // TODO: order these by most commonly used
        if (
            sig == PerpetualTokenAction.perpetualTokenTotalSupply.selector ||
            sig == PerpetualTokenAction.perpetualTokenBalanceOf.selector ||
            sig == PerpetualTokenAction.perpetualTokenTransferAllowance.selector ||
            sig == PerpetualTokenAction.perpetualTokenTransferApprove.selector ||
            sig == PerpetualTokenAction.perpetualTokenTransfer.selector ||
            sig == PerpetualTokenAction.perpetualTokenTransferFrom.selector ||
            sig == PerpetualTokenAction.perpetualTokenTransferApproveAll.selector ||
            sig == PerpetualTokenAction.perpetualTokenPresentValueAssetDenominated.selector ||
            sig == PerpetualTokenAction.perpetualTokenPresentValueUnderlyingDenominated.selector
        ) {
            return PERPETUAL_TOKEN_ACTIONS;
        }

        if (
            sig == MintPerpetualTokenAction.perpetualTokenMint.selector ||
            sig == MintPerpetualTokenAction.perpetualTokenMintFor.selector ||
            sig == MintPerpetualTokenAction.perpetualTokenRedeem.selector
        ) {
            return PERPETUAL_TOKEN_MINT;
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
            sig == GovernanceAction.updatePerpetualDepositParameters.selector ||
            sig == GovernanceAction.updateInitializationParameters.selector
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
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    fallback() external {
        _delegate(getRouterImplementation(msg.sig));
    }

}