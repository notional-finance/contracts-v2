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
        CurrencyStorage calldata cs
    ) external {
        require(id <= maxCurrencyId, "invalid currency id");
        currencyMapping[id] = cs;
    }

    /**
     * @dev This method does not update internal balances...must use currency handler.
     */
    function transfer(
        uint currencyId,
        address account,
        int netTransfer
    ) external returns (int) {
        Token memory token = TokenHandler.getToken(currencyId);
        return token.transfer(account, netTransfer);
    }

}