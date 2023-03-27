// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;

import "../../interfaces/notional/NotionalProxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockMaliciousETH {
    NotionalProxy immutable notional;

    constructor(NotionalProxy notional_) {
        notional = notional_;
    }

    function approveToken(ERC20 token) external {
        token.approve(address(notional), type(uint256).max);
    }

    function callNotional(bytes memory data) external payable {
        (bool status, bytes memory result) = address(notional).call{value: msg.value}(data);
        require(status, _getRevertMsg(result));
    }

    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (_returnData.length < 68) return "Transaction reverted silently";

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string)); // All that remains is the revert string
    }

    receive() external payable {
        // This should trip the re-entrancy check
        notional.withdraw(1, 100e8, true);
    }
}