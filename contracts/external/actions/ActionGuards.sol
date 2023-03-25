// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {StorageLayoutV1} from "../../global/StorageLayoutV1.sol";
import {Constants} from "../../global/Constants.sol";
import {nTokenHandler} from "../../internal/nToken/nTokenHandler.sol";

abstract contract ActionGuards is StorageLayoutV1 {
    uint256 internal constant _NOT_ENTERED = 1;
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
        require(account != address(0));
        require(account != Constants.FEE_RESERVE);
        require(account != Constants.SETTLEMENT_RESERVE);
        require(account != address(this));
        (
            uint256 isNToken,
            /* incentiveAnnualEmissionRate */,
            /* lastInitializedTime */,
            /* assetArrayLength */,
            /* parameters */
        ) = nTokenHandler.getNTokenContext(account);
        require(isNToken == 0);

        // NOTE: we do not check the pCash proxy here. Unlike the nToken, the pCash proxy
        // is a pure proxy and does not actually hold any assets. Any assets transferred
        // to the pCash proxy will be lost.
    }

    /// @dev Throws if called by any account other than the owner.
    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function _checkValidCurrency(uint16 currencyId) internal view {
        require(0 < currencyId && currencyId <= maxCurrencyId, "Invalid currency id");
    }
}