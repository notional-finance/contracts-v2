// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/TokenHandler.sol";

contract MockTokenHandler is StorageLayoutV1 {
    using TokenHandler for Token;

    function setMaxCurrencyId(uint16 num) external {
        maxCurrencyId = num;
    }

    function setCurrencyMapping(
        uint id,
        bool underlying,
        TokenStorage calldata ts
    ) external {
        return TokenHandler.setToken(id, underlying, ts);
    }

    /**
     * @dev This method does not update internal balances...must use currency handler.
     */
    function transfer(
        uint currencyId,
        address account,
        bool underlying,
        int netTransfer
    ) external returns (int) {
        Token memory token = TokenHandler.getToken(currencyId, underlying);
        return token.transfer(account, netTransfer);
    }

}