// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/AccountContextHandler.sol";
import "../internal/balances/BalanceHandler.sol";
import "../global/StorageLayoutV1.sol";

contract MockBalanceHandler is StorageLayoutV1 {
    using BalanceHandler for BalanceState;
    using AccountContextHandler for AccountContext;

    function setMaxCurrencyId(uint16 num) external {
        maxCurrencyId = num;
    }

    function getCurrencyMapping(uint16 id, bool underlying) external view returns (Token memory) {
        if (underlying) {
            return TokenHandler.getUnderlyingToken(id);
        } else {
            return TokenHandler.getAssetToken(id);
        }
    }

    function setCurrencyMapping(
        uint256 id,
        bool underlying,
        TokenStorage calldata ts
    ) external {
        TokenHandler.setToken(id, underlying, ts);
    }

    function setAccountContext(address account, AccountContext memory a) external {
        a.setAccountContext(account);
    }

    function setBalance(
        address account,
        uint256 currencyId,
        int256 cashBalance,
        int256 nTokenBalance
    ) external {
        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage.getBalanceStorage();
        BalanceStorage storage balanceStorage = store[account][currencyId];

        require(cashBalance >= type(int88).min && cashBalance <= type(int88).max); // dev: stored cash balance overflow
        // Allows for 12 quadrillion nToken balance in 1e8 decimals before overflow
        require(nTokenBalance >= 0 && nTokenBalance <= type(uint80).max); // dev: stored nToken balance overflow

        balanceStorage.nTokenBalance = uint80(nTokenBalance);
        balanceStorage.cashBalance = int88(cashBalance);
        balanceStorage.lastClaimTime = 0;
        balanceStorage.accountIncentiveDebt = 0;
    }

    function finalize(
        BalanceState memory balanceState,
        address account,
        AccountContext memory accountContext,
        bool redeemToUnderlying
    ) public returns (AccountContext memory, int256) {
        int256 transferAmountExternal = balanceState.finalize(account, accountContext, redeemToUnderlying);

        return (accountContext, transferAmountExternal);
    }

    function loadBalanceState(
        address account,
        uint16 currencyId,
        AccountContext memory accountContext
    ) public view returns (BalanceState memory, AccountContext memory) {
        BalanceState memory bs;
        bs.loadBalanceState(account, currencyId, accountContext);

        return (bs, accountContext);
    }

    function depositAssetToken(
        BalanceState memory balanceState,
        address account,
        int256 assetAmountExternal,
        bool forceTransfer
    ) external returns (BalanceState memory, int256) {
        int256 assetAmountInternal = balanceState.depositAssetToken(
            account,
            assetAmountExternal,
            forceTransfer
        );

        return (balanceState, assetAmountInternal);
    }

    function depositUnderlyingToken(
        BalanceState memory balanceState,
        address account,
        int256 underlyingAmountExternal
    ) external returns (BalanceState memory, int256) {
        int256 assetTokensReceivedInternal = balanceState.depositUnderlyingToken(
            account,
            underlyingAmountExternal
        );

        return (balanceState, assetTokensReceivedInternal);
    }

    function convertToExternal(uint16 currencyId, int256 amount) external view returns (int256) {
        return TokenHandler.convertToExternal(
            TokenHandler.getAssetToken(currencyId),
            amount
        );
    }

    function convertToInternal(uint16 currencyId, int256 amount) external view returns (int256) {
        return TokenHandler.convertToInternal(
            TokenHandler.getAssetToken(currencyId),
            amount
        );
    }
}
