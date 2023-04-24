// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;

import {Deployments} from "../../../global/Deployments.sol";
import {IEIP20NonStandard} from "../../../../interfaces/IEIP20NonStandard.sol";
import {SafeUint256} from "../../../math/SafeUint256.sol";

library GenericToken {
    using SafeUint256 for uint256;

    function transferNativeTokenOut(
        address account,
        uint256 amount,
        bool withdrawWrapped
    ) internal {
        // Native token withdraws are processed using .transfer() which is may not work
        // for certain contracts that do not implement receive() with minimal gas requirements.
        // Prior to the prime cash upgrade, these contracts could withdraw cETH, however, post
        // upgrade they no longer have this option. For these contracts, wrap the Native token
        // (i.e. WETH) and transfer that as an ERC20 instead.
        if (withdrawWrapped) {
            Deployments.WETH.deposit{value: amount}();
            safeTransferOut(address(Deployments.WETH), account, amount);
        } else {
            // TODO: consider using .call with a manual amount of gas forwarding
            payable(account).transfer(amount);
        }
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
    ) internal returns (uint256) {
        uint256 startingBalance = IEIP20NonStandard(token).balanceOf(address(this));

        IEIP20NonStandard(token).transferFrom(account, address(this), amount);
        checkReturnCode();

        uint256 endingBalance = IEIP20NonStandard(token).balanceOf(address(this));

        return endingBalance.sub(startingBalance);
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

    function executeLowLevelCall(
        address target,
        uint256 msgValue,
        bytes memory callData
    ) internal {
        (bool status, bytes memory returnData) = target.call{value: msgValue}(callData);
        require(status, checkRevertMessage(returnData));
    }

    function checkRevertMessage(bytes memory returnData) internal pure returns (string memory) {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (returnData.length < 68) return "Silent Revert";

        assembly {
            // Slice the sighash.
            returnData := add(returnData, 0x04)
        }
        return abi.decode(returnData, (string)); // All that remains is the revert string
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