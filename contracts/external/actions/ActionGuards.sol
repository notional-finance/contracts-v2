// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../../global/StorageLayoutV1.sol";
import "../../internal/nTokenHandler.sol";

abstract contract ActionGuards is StorageLayoutV1 {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    function initializeReentrancyGuard() internal {
        require(reentrancyStatus == 0);

        // Initialize the guard to a non-zero value, see the OZ reentrancy guard
        // description for why this is more gas efficient:
        // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/security/ReentrancyGuard.sol
        reentrancyStatus = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(reentrancyStatus != _ENTERED, "Reentrant call");

        // Any calls to nonReentrant after this point will fail
        reentrancyStatus = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        reentrancyStatus = _NOT_ENTERED;
    }

    // These accounts cannot receive deposits, transfers, fCash or any other
    // types of value transfers.
    function requireValidAccount(address account) internal view {
        require(account != Constants.RESERVE); // Reserve address is address(0)
        require(account != address(this));
        (
            uint256 isNToken,
            /* incentiveAnnualEmissionRate */,
            /* lastInitializedTime */,
            /* assetArrayLength */,
            /* parameters */
        ) = nTokenHandler.getNTokenContext(account);
        require(isNToken == 0);
    }


}