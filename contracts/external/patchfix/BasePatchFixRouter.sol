// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../proxy/utils/UUPSUpgradeable.sol";
import "../../../interfaces/notional/NotionalProxy.sol";

/**
 * Allows upgrades to the router while running some patch fix code that should never
 * be run again.
 */
abstract contract BasePatchFixRouter is UUPSUpgradeable {
    address public immutable OWNER;
    address public immutable FINAL_ROUTER;
    address public immutable CURRENT_ROUTER;
    NotionalProxy public immutable NOTIONAL;
    /// @dev This is used to identify the contract's deployed address when called
    /// inside a delegate call
    address public immutable SELF = address(this);

    constructor(address currentRouter, address finalRouter, NotionalProxy proxy) {
        FINAL_ROUTER = finalRouter;
        NOTIONAL = proxy;
        CURRENT_ROUTER = currentRouter;
        OWNER = proxy.owner();
    }

    function returnOwnership() external {
        require(msg.sender == OWNER);
        NOTIONAL.transferOwnership(OWNER, true);
    }

    /// @notice The owner of the proxy can call this method to run the patch fix code
    /// and upgrade the router. The owner must first transfer ownership to this contract,
    /// so that the upgrade methods can succeed. At the end of the method, ownership will be transferred
    /// back to the owner.
    function atomicPatchAndUpgrade() external {
        require(msg.sender == OWNER);
        // First claim ownership via the transfer
        NOTIONAL.claimOwnership();
        NOTIONAL.upgradeToAndCall(
            SELF,
            abi.encodeWithSelector(BasePatchFixRouter.patchFix.selector)
        );
        NOTIONAL.upgradeTo(FINAL_ROUTER);
        // Do a direct transfer back to the owner
        NOTIONAL.transferOwnership(OWNER, true);
        // Safety check that we do not lose ownership
        require(NOTIONAL.owner() == OWNER);
        selfdestruct(payable(OWNER));
    }

    /// @dev Only authorizes an upgrades to the specific destination contract
    function _authorizeUpgrade(address newImplementation) internal view override {
        require(
            msg.sender == SELF &&
                (newImplementation == FINAL_ROUTER || newImplementation == CURRENT_ROUTER)
        );
    }

    /// @dev Can only be called by this contract during the `upgradeToAndCall` method
    function patchFix() external {
        require(msg.sender == SELF);
        _patchFix();
    }

    function _patchFix() internal virtual;
}
