// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageLayoutV1.sol";
import "./BalanceHandler.sol";

library AccountContextHandler {
    bytes18 private constant ZERO = bytes18(0);

    /**
     * @notice Checks if a currency id (uint16 max) is in the 9 slots in the account
     * context active currencies list.
     */
    function isActiveCurrency(
        AccountStorage memory accountContext,
        uint currencyId
    ) internal pure returns (bool) {
        bytes18 currencies = accountContext.activeCurrencies;
        require(
            currencyId != 0 && currencyId <= type(uint16).max,
            "AC: invalid currency id"
        );
        
        if (accountContext.bitmapCurrencyId == currencyId) return true;

        while (currencies != ZERO) {
            if (uint(uint16(bytes2(currencies))) == currencyId) return true;
            currencies = currencies << 16;
        }

        return false;
    }

    /**
     * @notice Iterates through the active currency list and removes, inserts or does nothing
     * to ensure that the active currency list is an ordered byte array of uint16 currency ids
     * that refer to the currencies that an account is active in.
     *
     * This is called to ensure that currencies are active when the account has a non zero cash balance,
     * a non zero perpetual token balance or a portfolio asset.
     */
    function setActiveCurrency(
        AccountStorage memory accountContext,
        uint currencyId,
        bool isActive
    ) internal pure {
        require(
            currencyId != 0 && currencyId <= type(uint16).max,
            "AC: invalid currency id"
        );
        
        // If the bitmapped currency is already set then return here. Turning off the bitmap currency
        // id requires other logical handling so we will do it elsewhere.
        if (isActive && accountContext.bitmapCurrencyId == currencyId) return;

        bytes18 prefix;
        bytes18 suffix = accountContext.activeCurrencies;
        uint shifts;

        /**
         * There are six possible outcomes from this search:
         * 1. The currency id is in the list
         *      - it must be set to active, do nothing
         *      - it must be set to inactive, shift suffix and concatenate
         * 2. The current id is greater than the one in the search:
         *      - it must be set to active, append to prefix and then concatenate the suffix,
         *        ensure that we do not lose the last 2 bytes if set.
         *      - it must be set to inactive, it is not in the list, do nothing
         * 3. Reached the end of the list:
         *      - it must be set to active, check that the last two bytes are not set and then
         *        append to the prefix
         *      - it must be set to inactive, do nothing
         */
        while (suffix != ZERO) {
            uint cid = uint(uint16(bytes2(suffix)));
            // if matches and isActive then return, already in list
            if (cid == currencyId && isActive) return;
            // if matches and not active then shift suffix to remove
            if (cid == currencyId && !isActive) {
                suffix = suffix << 16;
                accountContext.activeCurrencies = prefix | suffix >> (shifts * 16);
                return;
            }

            // if greater than and isActive then insert into prefix
            if (cid > currencyId && isActive) {
                prefix = prefix | bytes18(bytes2(uint16(currencyId))) >> (shifts * 16);
                // check that the total length is not greater than 9
                require(
                    accountContext.activeCurrencies[16] == 0x00 && accountContext.activeCurrencies[17] == 0x00,
                    "AC: too many currencies"
                );

                // append the suffix
                accountContext.activeCurrencies = prefix | suffix >> ((shifts + 1) * 16);
                return;
            }

            // if past the point of the currency id and not active, not in list
            if (cid > currencyId && !isActive) return;

            prefix = prefix | (bytes18(bytes2(suffix)) >> (shifts * 16));
            suffix = suffix << 16;
            shifts += 1;
        }

        // If reached this point and not active then return
        if (!isActive) return;

        // if end and isActive then insert into suffix, check max length
        require(
            accountContext.activeCurrencies[16] == 0x00 && accountContext.activeCurrencies[17] == 0x00,
            "AC: too many currencies"
        );
        accountContext.activeCurrencies = prefix | bytes18(bytes2(uint16(currencyId))) >> (shifts * 16);
    }

    /**
     * @notice With gas repricing of warm storage reads, this is probably cheaper than a more complex
     * method of using cached in memory balances. The additional re-read of storage is only 100 gas.
     *
     * @dev Should this be merged with get all cash groups?
     */
    function getAllBalances(
        AccountStorage memory accountContext,
        address account
    ) internal view returns (BalanceState[] memory) {
        bytes18 currencies = accountContext.activeCurrencies;
        uint bitmapCurrencyId = accountContext.bitmapCurrencyId;
        uint totalBalances;
        if (bitmapCurrencyId != 0) totalBalances += 1;

        // Count total balances
        while (currencies != ZERO) {
            totalBalances += 1;
            currencies = currencies << 16;
        }

        BalanceState[] memory balanceStates = new BalanceState[](totalBalances);
        currencies = accountContext.activeCurrencies;
        for (uint i; i < totalBalances; i++) {
            uint id = uint(uint16(bytes2(currencies)));

            // The bitmap currency may be inside the list or at the end
            if (bitmapCurrencyId != 0 && (bitmapCurrencyId < id || i == (totalBalances - 1))) {
                balanceStates[i].currencyId = bitmapCurrencyId;
                (
                    balanceStates[i].storedCashBalance,
                    balanceStates[i].storedPerpetualTokenBalance
                ) = BalanceHandler.getBalanceStorage(account, bitmapCurrencyId);
                // Set this to zero if it's already been set
                bitmapCurrencyId = 0;
                continue;
            }

            balanceStates[i].currencyId = id;
            (
                balanceStates[i].storedCashBalance,
                balanceStates[i].storedPerpetualTokenBalance
            ) = BalanceHandler.getBalanceStorage(account, id);
            currencies = currencies << 16;
        }

        return balanceStates;
    }

    // function mintIncentives
}