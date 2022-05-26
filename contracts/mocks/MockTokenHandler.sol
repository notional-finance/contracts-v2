// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/balances/TokenHandler.sol";
import "../global/StorageLayoutV1.sol";

contract MockTokenHandler is StorageLayoutV1 {
    using TokenHandler for Token;

    function setMaxCurrencyId(uint16 num) external {
        maxCurrencyId = num;
    }

    function setCurrencyMapping(
        uint256 id,
        bool underlying,
        TokenStorage calldata ts
    ) external {
        return TokenHandler.setToken(id, underlying, ts);
    }

    function setMaxCollateralBalance(uint256 currencyId, uint72 maxCollateralBalance) external {
        TokenHandler.setMaxCollateralBalance(currencyId, maxCollateralBalance);
    }

    function transfer(
        uint16 currencyId,
        address account,
        bool underlying,
        int256 netTransfer
    ) external returns (int256) {
        Token memory token;
        if (underlying) {
            token = TokenHandler.getUnderlyingToken(currencyId);
        } else {
            token = TokenHandler.getAssetToken(currencyId);
        }
        return token.transfer(account, currencyId, netTransfer);
    }

    function mint(uint16 currencyId, uint256 underlyingAmount) external payable returns (int256) {
        Token memory token = TokenHandler.getAssetToken(currencyId);
        return token.mint(currencyId, underlyingAmount);
    }

    function redeem(uint16 currencyId, uint256 assetAmountExternal) external returns (int256) {
        Token memory token = TokenHandler.getAssetToken(currencyId);
        return token.redeem(currencyId, msg.sender, assetAmountExternal);
    }

    function getToken(uint16 currencyId, bool underlying) external view returns (Token memory) {
        if (underlying) {
            return TokenHandler.getUnderlyingToken(currencyId);
        } else {
            return TokenHandler.getAssetToken(currencyId);
        }
    }

    receive() external payable { }
}
