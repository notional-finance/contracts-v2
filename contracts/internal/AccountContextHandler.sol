// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../global/LibStorage.sol";
import "./balances/BalanceHandler.sol";
import "./portfolio/BitmapAssetsHandler.sol";
import "./portfolio/PortfolioHandler.sol";

library AccountContextHandler {
    using PortfolioHandler for PortfolioState;

    bytes18 private constant TURN_OFF_PORTFOLIO_FLAGS = 0x7FFF7FFF7FFF7FFF7FFF7FFF7FFF7FFF7FFF;
    event AccountContextUpdate(address indexed account);

    /// @notice Returns the account context of a given account
    function getAccountContext(address account) internal view returns (AccountContext memory) {
        mapping(address => AccountContext) storage store = LibStorage.getAccountStorage();
        return store[account];
    }

    /// @notice Sets the account context of a given account
    function setAccountContext(AccountContext memory accountContext, address account) internal {
        mapping(address => AccountContext) storage store = LibStorage.getAccountStorage();
        store[account] = accountContext;
        emit AccountContextUpdate(account);
    }

    function isBitmapEnabled(AccountContext memory accountContext) internal pure returns (bool) {
        return accountContext.bitmapCurrencyId != 0;
    }

    /// @notice Enables a bitmap type portfolio for an account. A bitmap type portfolio allows
    /// an account to hold more fCash than a normal portfolio, except only in a single currency.
    /// Once enabled, it cannot be disabled or changed. An account can only enable a bitmap if
    /// it has no assets or debt so that we ensure no assets are left stranded.
    /// @param accountContext refers to the account where the bitmap will be enabled
    /// @param currencyId the id of the currency to enable
    /// @param blockTime the current block time to set the next settle time
    function enableBitmapForAccount(
        AccountContext memory accountContext,
        uint16 currencyId,
        uint256 blockTime
    ) internal pure {
        require(!isBitmapEnabled(accountContext), "Cannot change bitmap");
        require(0 < currencyId && currencyId <= Constants.MAX_CURRENCIES, "Invalid currency id");

        // Account cannot have assets or debts
        require(accountContext.assetArrayLength == 0, "Cannot have assets");
        require(accountContext.hasDebt == 0x00, "Cannot have debt");

        // Ensure that the active currency is set to false in the array so that there is no double
        // counting during FreeCollateral
        setActiveCurrency(accountContext, currencyId, false, Constants.ACTIVE_IN_BALANCES);
        accountContext.bitmapCurrencyId = currencyId;

        // Setting this is required to initialize the assets bitmap
        uint256 nextSettleTime = DateTime.getTimeUTC0(blockTime);
        require(nextSettleTime < type(uint40).max); // dev: blockTime overflow
        accountContext.nextSettleTime = uint40(nextSettleTime);
    }

    /// @notice Returns true if the context needs to settle
    function mustSettleAssets(AccountContext memory accountContext) internal view returns (bool) {
        uint256 blockTime = block.timestamp;

        if (isBitmapEnabled(accountContext)) {
            // nextSettleTime will be set to utc0 after settlement so we
            // settle if this is strictly less than utc0
            return accountContext.nextSettleTime < DateTime.getTimeUTC0(blockTime);
        } else {
            // 0 value occurs on an uninitialized account
            // Assets mature exactly on the blockTime (not one second past) so in this
            // case we settle on the block timestamp
            return 0 < accountContext.nextSettleTime && accountContext.nextSettleTime <= blockTime;
        }
    }

    /// @notice Checks if a currency id (uint16 max) is in the 9 slots in the account
    /// context active currencies list.
    /// @dev NOTE: this may be more efficient as a binary search since we know that the array
    /// is sorted
    function isActiveInBalances(AccountContext memory accountContext, uint256 currencyId)
        internal
        pure
        returns (bool)
    {
        require(currencyId != 0 && currencyId <= Constants.MAX_CURRENCIES); // dev: invalid currency id
        bytes18 currencies = accountContext.activeCurrencies;

        if (accountContext.bitmapCurrencyId == currencyId) return true;

        while (currencies != 0x00) {
            uint256 cid = uint16(bytes2(currencies) & Constants.UNMASK_FLAGS);
            if (cid == currencyId) {
                // Currency found, return if it is active in balances or not
                return bytes2(currencies) & Constants.ACTIVE_IN_BALANCES == Constants.ACTIVE_IN_BALANCES;
            }

            currencies = currencies << 16;
        }

        return false;
    }

    /// @notice Iterates through the active currency list and removes, inserts or does nothing
    /// to ensure that the active currency list is an ordered byte array of uint16 currency ids
    /// that refer to the currencies that an account is active in.
    ///
    /// This is called to ensure that currencies are active when the account has a non zero cash balance,
    /// a non zero nToken balance or a portfolio asset.
    function setActiveCurrency(
        AccountContext memory accountContext,
        uint256 currencyId,
        bool isActive,
        bytes2 flags
    ) internal pure {
        require(0 < currencyId && currencyId <= Constants.MAX_CURRENCIES); // dev: invalid currency id

        // If the bitmapped currency is already set then return here. Turning off the bitmap currency
        // id requires other logical handling so we will do it elsewhere.
        if (isActive && accountContext.bitmapCurrencyId == currencyId) return;

        bytes18 prefix;
        bytes18 suffix = accountContext.activeCurrencies;
        uint256 shifts;

        /// There are six possible outcomes from this search:
        /// 1. The currency id is in the list
        ///      - it must be set to active, do nothing
        ///      - it must be set to inactive, shift suffix and concatenate
        /// 2. The current id is greater than the one in the search:
        ///      - it must be set to active, append to prefix and then concatenate the suffix,
        ///        ensure that we do not lose the last 2 bytes if set.
        ///      - it must be set to inactive, it is not in the list, do nothing
        /// 3. Reached the end of the list:
        ///      - it must be set to active, check that the last two bytes are not set and then
        ///        append to the prefix
        ///      - it must be set to inactive, do nothing
        while (suffix != 0x00) {
            uint256 cid = uint256(uint16(bytes2(suffix) & Constants.UNMASK_FLAGS));
            // if matches and isActive then return, already in list
            if (cid == currencyId && isActive) {
                // set flag and return
                accountContext.activeCurrencies =
                    accountContext.activeCurrencies |
                    (bytes18(flags) >> (shifts * 16));
                return;
            }

            // if matches and not active then shift suffix to remove
            if (cid == currencyId && !isActive) {
                // turn off flag, if both flags are off then remove
                suffix = suffix & ~bytes18(flags);
                if (bytes2(suffix) & ~Constants.UNMASK_FLAGS == 0x0000) suffix = suffix << 16;
                accountContext.activeCurrencies = prefix | (suffix >> (shifts * 16));
                return;
            }

            // if greater than and isActive then insert into prefix
            if (cid > currencyId && isActive) {
                prefix = prefix | (bytes18(bytes2(uint16(currencyId)) | flags) >> (shifts * 16));
                // check that the total length is not greater than 9, meaning that the last
                // two bytes of the active currencies array should be zero
                require((accountContext.activeCurrencies << 128) == 0x00); // dev: AC: too many currencies

                // append the suffix
                accountContext.activeCurrencies = prefix | (suffix >> ((shifts + 1) * 16));
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
        require(shifts < 9); // dev: AC: too many currencies
        accountContext.activeCurrencies =
            prefix |
            (bytes18(bytes2(uint16(currencyId)) | flags) >> (shifts * 16));
    }

    function _clearPortfolioActiveFlags(bytes18 activeCurrencies) internal pure returns (bytes18) {
        bytes18 result;
        // This is required to clear the suffix as we append below
        bytes18 suffix = activeCurrencies & TURN_OFF_PORTFOLIO_FLAGS;
        uint256 shifts;

        // This loop will append all currencies that are active in balances into the result.
        while (suffix != 0x00) {
            if (bytes2(suffix) & Constants.ACTIVE_IN_BALANCES == Constants.ACTIVE_IN_BALANCES) {
                // If any flags are active, then append.
                result = result | (bytes18(bytes2(suffix)) >> shifts);
                shifts += 16;
            }
            suffix = suffix << 16;
        }

        return result;
    }

    /// @notice Stores a portfolio array and updates the account context information, this method should
    /// be used whenever updating a portfolio array except in the case of nTokens
    function storeAssetsAndUpdateContext(
        AccountContext memory accountContext,
        address account,
        PortfolioState memory portfolioState,
        bool isLiquidation
    ) internal {
        // Each of these parameters is recalculated based on the entire array of assets in store assets,
        // regardless of whether or not they have been updated.
        (bool hasDebt, bytes32 portfolioCurrencies, uint8 assetArrayLength, uint40 nextSettleTime) =
            portfolioState.storeAssets(account);
        accountContext.nextSettleTime = nextSettleTime;
        require(mustSettleAssets(accountContext) == false); // dev: cannot store matured assets
        accountContext.assetArrayLength = assetArrayLength;

        // During liquidation it is possible for an array to go over the max amount of assets allowed due to
        // liquidity tokens being withdrawn into fCash.
        if (!isLiquidation) {
            require(assetArrayLength <= uint8(Constants.MAX_TRADED_MARKET_INDEX)); // dev: max assets allowed
        }

        // Sets the hasDebt flag properly based on whether or not portfolio has asset debt, meaning
        // a negative fCash balance.
        if (hasDebt) {
            accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_ASSET_DEBT;
        } else {
            // Turns off the ASSET_DEBT flag
            accountContext.hasDebt = accountContext.hasDebt & ~Constants.HAS_ASSET_DEBT;
        }

        // Clear the active portfolio active flags and they will be recalculated in the next step
        accountContext.activeCurrencies = _clearPortfolioActiveFlags(accountContext.activeCurrencies);

        uint256 lastCurrency;
        while (portfolioCurrencies != 0) {
            // Portfolio currencies will not have flags, it is just an byte array of all the currencies found
            // in a portfolio. They are appended in a sorted order so we can compare to the previous currency
            // and only set it if they are different.
            uint256 currencyId = uint16(bytes2(portfolioCurrencies));
            if (currencyId != lastCurrency) {
                setActiveCurrency(accountContext, currencyId, true, Constants.ACTIVE_IN_PORTFOLIO);
            }
            lastCurrency = currencyId;

            portfolioCurrencies = portfolioCurrencies << 16;
        }
    }
}
