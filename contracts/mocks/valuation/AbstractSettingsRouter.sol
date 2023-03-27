// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {PrimeCashProxy} from "../../external/proxies/PrimeCashProxy.sol";
import {ITransferEmitter} from "../../external/proxies/BaseERC4626Proxy.sol";
import {NotionalProxy} from "../../../interfaces/notional/NotionalProxy.sol";

abstract contract AbstractSettingsRouter {
    address public immutable settings;
    address public immutable DUMMY_PROXY;

    constructor(address settingsLib) {
        settings = settingsLib;
        PrimeCashProxy dummy = new PrimeCashProxy(NotionalProxy(address(this)));
        // NOTE: this proxy won't actually do anything, but event emits will be routed to it
        DUMMY_PROXY = address(dummy);
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
        bytes4 sig = msg.sig;
        if (
            sig == ITransferEmitter.emitTransfer.selector ||
            sig == ITransferEmitter.emitMintOrBurn.selector ||
            sig == ITransferEmitter.emitMintTransferBurn.selector ||
            sig == ITransferEmitter.emitfCashTradeTransfers.selector
        ) {
            _delegate(DUMMY_PROXY);
        } else {
            _delegate(settings);
        }
    }

    receive() external payable {}

}