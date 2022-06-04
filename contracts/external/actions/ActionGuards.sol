// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../global/StorageLayoutV1.sol";
import "../../internal/nToken/nTokenHandler.sol";

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

    /// @dev Throws if called by any account other than the owner.
    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function _checkValidCurrency(uint16 currencyId) internal view {
        require(0 < currencyId && currencyId <= maxCurrencyId, "Invalid currency id");
    }
}