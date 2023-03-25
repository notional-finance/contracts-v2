// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;

import {Deployments} from "../../../global/Deployments.sol";
import {IEIP20NonStandard} from "../../../../interfaces/IEIP20NonStandard.sol";
import {SafeUint256} from "../../../math/SafeUint256.sol";

library GenericToken {
    using SafeUint256 for uint256;

    function transferNativeTokenOut(
        address account,
        uint256 amount
    ) internal {
        // This does not work with contracts, but is reentrancy safe. If contracts want to withdraw underlying
        // ETH they will have to withdraw the cETH token and then redeem it manually.
        payable(account).transfer(amount);
    }

    function safeTransferOut(
        address token,
        address account,
        uint256 amount
    ) internal {
        IEIP20NonStandard(token).transfer(account, amount);
        checkReturnCode();
    }

    function safeTransferIn(
        address token,
        address account,
        uint256 amount
    ) internal {
        IEIP20NonStandard(token).transferFrom(account, address(this), amount);
        checkReturnCode();
    }

    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        IEIP20NonStandard(token).transferFrom(from, to, amount);
        checkReturnCode();
    }

    function checkReturnCode() internal pure {
        bool success;
        uint256[1] memory result;
        assembly {
            switch returndatasize()
                case 0 {
                    // This is a non-standard ERC-20
                    success := 1 // set success to true
                }
                case 32 {
                    // This is a compliant ERC-20
                    returndatacopy(result, 0, 32)
                    success := mload(result) // Set `success = returndata` of external call
                }
                default {
                    // This is an excessively non-compliant ERC-20, revert.
                    revert(0, 0)
                }
        }

        require(success, "ERC20");
    }

}