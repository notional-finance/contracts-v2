// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../internal/AccountContextHandler.sol";
import "../internal/balances/BalanceHandler.sol";
import "../global/StorageLayoutV1.sol";

contract MockBalanceHandler is StorageLayoutV1 {
    using BalanceHandler for BalanceState;
    using AccountContextHandler for AccountStorage;

    function setMaxCurrencyId(uint16 num) external {
        maxCurrencyId = num;
    }

    function getCurrencyMapping(uint256 id, bool underlying) external view returns (Token memory) {
        return TokenHandler.getToken(id, underlying);
    }

    function setCurrencyMapping(
        uint256 id,
        bool underlying,
        TokenStorage calldata ts
    ) external {
        TokenHandler.setToken(id, underlying, ts);
    }

    function setAccountContext(address account, AccountStorage memory a) external {
        a.setAccountContext(account);
    }

    function setBalance(
        address account,
        uint256 currencyId,
        int256 storedCashBalance,
        int256 storedPerpetualTokenBalance
    ) external {
        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));

        require(
            storedCashBalance >= type(int128).min && storedCashBalance <= type(int128).max,
            "CH: cash balance overflow"
        );

        require(
            storedPerpetualTokenBalance >= 0 && storedPerpetualTokenBalance <= type(uint128).max,
            "CH: token balance overflow"
        );

        bytes32 data =
            (// Truncate the higher bits of the signed integer when it is negative
            (bytes32(uint256(storedPerpetualTokenBalance))) | (bytes32(storedCashBalance) << 128));

        assembly {
            sstore(slot, data)
        }
    }

    function getData(address account, uint256 currencyId) external view returns (bytes32) {
        bytes32 slot = keccak256(abi.encode(currencyId, account, "account.balances"));
        bytes32 data;
        assembly {
            data := sload(slot)
        }

        return data;
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

    function loadBalanceState(
        address account,
        uint256 currencyId,
        AccountStorage memory accountContext
    ) public view returns (BalanceState memory, AccountStorage memory) {
        BalanceState memory bs;
        bs.loadBalanceState(account, currencyId, accountContext);

        return (bs, accountContext);
    }

    function depositAssetToken(
        BalanceState memory balanceState,
        address account,
        int256 assetAmountExternal,
        bool forceTransfer
    )
        external
        returns (
            BalanceState memory,
            int256,
            int256
        )
    {
        (int256 assetAmountInternal, int256 assetAmountTransferred) =
            balanceState.depositAssetToken(account, assetAmountExternal, forceTransfer);

        return (balanceState, assetAmountInternal, assetAmountTransferred);
    }

    function depositUnderlyingToken(
        BalanceState memory balanceState,
        address account,
        int256 underlyingAmountExternal
    ) external returns (BalanceState memory, int256) {
        int256 assetTokensReceivedInternal =
            balanceState.depositUnderlyingToken(account, underlyingAmountExternal);

        return (balanceState, assetTokensReceivedInternal);
    }
}
