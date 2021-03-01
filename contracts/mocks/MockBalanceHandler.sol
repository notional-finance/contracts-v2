// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../storage/BalanceHandler.sol";
import "../storage/StorageLayoutV1.sol";

contract MockBalanceHandler is StorageLayoutV1 {
    using BalanceHandler for BalanceState;

    function setMaxCurrencyId(uint16 num) external {
        maxCurrencyId = num;
    }

    function getCurrencyMapping(
        uint id,
        bool underlying
    ) external view returns (Token memory) {
        return TokenHandler.getToken(id, underlying);
    }

    function setCurrencyMapping(
        uint id,
        bool underlying,
        TokenStorage calldata ts
    ) external {
        TokenHandler.setToken(id, underlying, ts);
    }

    function setAccountContext(
        address account,
        AccountStorage memory a
    ) external {
        accountContextMapping[account] = a;
    }

    function setBalance(
        address account,
        uint currencyId,
        int storedCashBalance,
        int storedPerpetualTokenBalance
    ) external {
        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));

        require(
            storedCashBalance >= type(int128).min
            && storedCashBalance <= type(int128).max,
            "CH: cash balance overflow"
        );

        require(
            storedPerpetualTokenBalance >= 0
            && storedPerpetualTokenBalance <= type(uint128).max,
            "CH: token balance overflow"
        );

        bytes32 data = (
            // Truncate the higher bits of the signed integer when it is negative
            (bytes32(uint(storedPerpetualTokenBalance))) |
            (bytes32(storedCashBalance) << 128)
        );

        assembly { sstore(slot, data) }
    }

    function getData(
        address account,
        uint currencyId
    ) external view returns (bytes32) {
        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));
        bytes32 data;
        assembly { data := sload(slot) }

        return data;
    }

    function getPerpetualTokenAssetValue(
        BalanceState memory balanceState
    ) public pure returns (int) {
        return balanceState.getPerpetualTokenAssetValue();
    }

    function getCurrencyIncentiveData(
        uint currencyId
    ) public view returns (uint) {
        return BalanceHandler.getCurrencyIncentiveData(currencyId);
    }

    function finalize(
        BalanceState memory balanceState,
        address account,
        AccountStorage memory accountContext,
        bool redeemToUnderlying
    ) public returns (AccountStorage memory) {
        balanceState.finalize(account, accountContext, redeemToUnderlying);

        return accountContext;
    }

    function buildBalanceState(
        address account,
        uint currencyId,
        AccountStorage memory accountContext
    ) public view returns (BalanceState memory, AccountStorage memory) {
        BalanceState memory bs = BalanceHandler.buildBalanceState(
            account,
            currencyId,
            accountContext
        );

        return (bs, accountContext);
    }

    function depositAssetToken(
        BalanceState memory balanceState,
        address account,
        int assetAmountExternalPrecision,
        bool useCashBalance
    ) external returns (BalanceState memory, int, int) {
        (int assetAmountInternal, int assetAmountTransferred) = balanceState.depositAssetToken(
            account,
            assetAmountExternalPrecision,
            useCashBalance
        );

        return (balanceState, assetAmountInternal, assetAmountTransferred);
    }

    function depositUnderlyingToken(
        BalanceState memory balanceState,
        address account,
        int underlyingAmountExternalPrecision
    ) external returns (BalanceState memory, int) {
        int assetTokensReceivedInternal = balanceState.depositUnderlyingToken(
            account,
            underlyingAmountExternalPrecision
        );

        return (balanceState, assetTokensReceivedInternal);
    }
}