// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageLayoutV1.sol";
import "./BalanceHandler.sol";
import "./PortfolioHandler.sol";

library AccountContextHandler {
    using PortfolioHandler for PortfolioState;

    bytes18 private constant ZERO = bytes18(0);
    bytes1 internal constant HAS_ASSET_DEBT = 0x01;
    bytes1 internal constant HAS_CASH_DEBT = 0x02;
    bytes2 internal constant ACTIVE_IN_PORTFOLIO_FLAG = 0x8000;
    bytes2 internal constant ACTIVE_IN_BALANCES_FLAG = 0x4000;
    bytes2 internal constant UNMASK_FLAGS = 0x3FFF;
    uint16 internal constant MAX_CURRENCIES = uint16(UNMASK_FLAGS);
    bytes18 internal constant UNMASK_ALL_ACTIVE_CURRENCIES = 0x3FFF3FFF3FFF3FFF3FFF3FFF3FFF3FFF3FFF;
    bytes18 internal constant TURN_OFF_PORTFOLIO_FLAGS = 0x7FFF7FFF7FFF7FFF7FFF7FFF7FFF7FFF7FFF;
    
    function getAccountContext(
        address account
    ) internal view returns (AccountStorage memory) {
        bytes32 slot = keccak256(abi.encode(account, "account.context"));
        bytes32 data;

        assembly { data := sload(slot) }

        return AccountStorage({
            nextSettleTime: uint40(uint(data)),
            hasDebt: bytes1(data << 208),
            assetArrayLength: uint8(uint(data >> 48)),
            bitmapCurrencyId: uint16(uint(data >> 56)),
            activeCurrencies: bytes18(data << 40)
        });
    }

    function setAccountContext(
        AccountStorage memory accountContext,
        address account
    ) internal {
        bytes32 slot = keccak256(abi.encode(account, "account.context"));
        bytes32 data = (
            bytes32(uint(accountContext.nextSettleTime)) |
            bytes32(accountContext.hasDebt) >> 208 |
            bytes32(uint(accountContext.assetArrayLength)) << 48 |
            bytes32(uint(accountContext.bitmapCurrencyId)) << 56 |
            bytes32(accountContext.activeCurrencies) >> 40
        );

        assembly { sstore (slot, data) }
    }

    function enableBitmapForAccount(
        AccountStorage memory accountContext,
        address account,
        uint currencyId
    ) internal view {
        // Allow setting the currency id to zero to turn off bitmap
        require(currencyId <= MAX_CURRENCIES, "AC: invalid currency id");
        if (accountContext.bitmapCurrencyId == 0) {
            require(accountContext.assetArrayLength == 0, "AC: cannot have assets");
        } else {
            bytes32 ifCashBitmap = BitmapAssetsHandler.getAssetsBitmap(account, accountContext.bitmapCurrencyId);
            require(ifCashBitmap == 0, "AC: cannot have assets");
        }

        accountContext.bitmapCurrencyId = uint16(currencyId);
    }

    function mustSettleAssets(
        AccountStorage memory accountContext
    ) internal view returns (bool) {
        return (accountContext.nextSettleTime != 0 && accountContext.nextSettleTime <= block.timestamp);
    }

    /**
     * @notice Checks if a currency id (uint16 max) is in the 9 slots in the account
     * context active currencies list.
     */
    function isActiveInBalances(
        AccountStorage memory accountContext,
        uint currencyId
    ) internal pure returns (bool) {
        bytes18 currencies = accountContext.activeCurrencies;
        require(currencyId != 0 && currencyId <= MAX_CURRENCIES, "AC: invalid currency id");
        
        if (accountContext.bitmapCurrencyId == currencyId) return true;

        while (currencies != ZERO) {
            uint cid = uint(uint16(bytes2(currencies) & UNMASK_FLAGS));
            bool isActive = bytes2(currencies) & ACTIVE_IN_BALANCES_FLAG == ACTIVE_IN_BALANCES_FLAG;

            if (cid == currencyId && isActive) return true;
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
        bool isActive,
        bytes2 flags
    ) internal pure {
        require(currencyId != 0 && currencyId <= MAX_CURRENCIES, "AC: invalid currency id");
        
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
            uint cid = uint(uint16(bytes2(suffix) & UNMASK_FLAGS));
            // if matches and isActive then return, already in list
            if (cid == currencyId && isActive) {
                // set flag and return
                accountContext.activeCurrencies = accountContext.activeCurrencies | (bytes18(flags) >> (shifts * 16));
                return;
            }

            // if matches and not active then shift suffix to remove
            if (cid == currencyId && !isActive) {
                // turn off flag, if both flags are off then remove
                suffix = suffix & ~bytes18(flags);
                if (bytes2(suffix) & ~UNMASK_FLAGS == 0x0000) suffix = suffix << 16;
                accountContext.activeCurrencies = prefix | suffix >> (shifts * 16);
                return;
            }

            // if greater than and isActive then insert into prefix
            if (cid > currencyId && isActive) {
                prefix = prefix | bytes18(bytes2(uint16(currencyId)) | flags) >> (shifts * 16);
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
        accountContext.activeCurrencies = prefix | (bytes18(bytes2(uint16(currencyId)) | flags) >> (shifts * 16));
    }

    function clearPortfolioActiveFlags(
        bytes18 activeCurrencies
    ) internal pure returns (bytes18) {
        bytes18 result;
        bytes18 suffix = activeCurrencies & TURN_OFF_PORTFOLIO_FLAGS;
        uint shifts;

        while (suffix != ZERO) {
            if (bytes2(suffix) & ACTIVE_IN_BALANCES_FLAG == ACTIVE_IN_BALANCES_FLAG) {
                // If any flags are active, then append.
                result = result | (bytes18(bytes2(suffix)) >> (shifts * 16));
                shifts += 1;
            }
            suffix = suffix << 16;
        }

        return result;
    }

    function storeAssetsAndUpdateContext(
        AccountStorage memory accountContext,
        address account,
        PortfolioState memory portfolioState
    ) internal {
        (
            bool hasDebt,
            bytes32 portfolioCurrencies,
            uint8 assetArrayLength,
            uint40 nextSettleTime
        ) = portfolioState.storeAssets(account);

        if (hasDebt) {
            accountContext.hasDebt = accountContext.hasDebt | HAS_ASSET_DEBT;
        } else {
            // Turns off the FCASH_DEBT flag
            accountContext.hasDebt = accountContext.hasDebt & HAS_CASH_DEBT;
        }
        accountContext.assetArrayLength = assetArrayLength;
        accountContext.nextSettleTime = nextSettleTime;

        uint lastCurrency;
        accountContext.activeCurrencies = clearPortfolioActiveFlags(accountContext.activeCurrencies);
        while (portfolioCurrencies != 0) {
            uint currencyId = uint(uint16(bytes2(portfolioCurrencies)));
            if (currencyId != lastCurrency) {
                setActiveCurrency(accountContext, currencyId, true, ACTIVE_IN_PORTFOLIO_FLAG);
            }
            lastCurrency = currencyId;

            portfolioCurrencies = portfolioCurrencies << 16;
        }
    }

}