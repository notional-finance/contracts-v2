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
        uint id
    ) external view returns (CurrencyStorage memory) {
        return currencyMapping[id];
    }

    function setCurrencyMapping(
        uint id,
        CurrencyStorage calldata cs
    ) external {
        require(id <= maxCurrencyId, "invalid currency id");
        currencyMapping[id] = cs;
    }

    function setAccountContext(
        address account,
        AccountStorage memory a
    ) external {
        accountContextMapping[account] = a;
    }

    function setBalance(
        address account,
        uint id,
        BalanceStorage calldata bs
    ) external {
        accountBalanceMapping[account][id] = bs;
    }

    function getPerpetualTokenAssetValue(
        BalanceState memory balanceState
    ) public pure returns (int) {
        return balanceState.getPerpetualTokenAssetValue();
    }

    function getCurrencyIncentiveData(
        uint currencyId
    ) public view returns (uint, uint) {
        return BalanceHandler.getCurrencyIncentiveData(currencyId);
    }

    function finalize(
        BalanceState memory balanceState,
        address account,
        AccountStorage memory accountContext
    ) public returns (AccountStorage memory) {
        balanceState.finalize(account, accountContext);

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
            accountContext.activeCurrencies
        );

        return (bs, accountContext);
    }

    function getRemainingActiveBalances(
        address account,
        AccountStorage memory accountContext,
        BalanceState[] memory balanceState
    ) public view returns (BalanceState[] memory, AccountStorage memory) {
        BalanceState[] memory bs = BalanceHandler.getRemainingActiveBalances(
            account,
            accountContext.activeCurrencies,
            balanceState
        );

        return (bs, accountContext);
    }

    function getData(address account, uint currencyId) public view returns (bytes32) {
        bytes32 slot = keccak256(abi.encode(currencyId, keccak256(abi.encode(account, BalanceHandler.BALANCE_STORAGE_SLOT))));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        return data;
    }
}