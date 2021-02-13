// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageLayoutV1.sol";
import "./TokenHandler.sol";
import "../math/Bitmap.sol";
import "../math/SafeInt256.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

struct BalanceState {
    uint currencyId;
    int storedCashBalance;
    int storedPerpetualTokenBalance;
    int netCashChange;
}

library BalanceHandler {
    using SafeInt256 for int;
    using SafeMath for uint;
    using Bitmap for bytes;
    using TokenHandler for Token;

    uint internal constant BALANCE_STORAGE_SLOT = 10;

    /**
     * @notice 
     */
    function getPerpetualTokenAssetValue(
        BalanceState memory balanceState
    ) internal pure returns (int) { return 0; }

    /**
     * @notice Call this in order to transfer cash in and out of the Notional system as well as update
     * internal cash balances.
     *
     * @dev This method will handle logic related to:
     * - Updating internal token balances
     * - Converting internal balances (1e9) to external balances
     * - Transferring ERC20 tokens and handling fees
     * - Managing perpetual liquidity token incentives
     * - Updates the account context which must also be saved when this is completed
     */
    function finalize(
        BalanceState memory balanceState,
        address account,
        AccountStorage memory accountContext,
        int netCashTransfer,
        int netPerpetualTokenTransfer
    ) internal {
        bool mustUpdate;
        if (netCashTransfer < 0) {
            // Transfer fees will always reduce netCashTransfer so the receiving account will receive less
            // but the Notional system will account for the total net cash transfer out here
            require(
                balanceState.storedCashBalance.add(balanceState.netCashChange) >= netCashTransfer.neg(),
                "CH: cannot withdraw negative"
            );
        }

        if (netPerpetualTokenTransfer < 0) {
            require(
                balanceState.storedPerpetualTokenBalance >= netPerpetualTokenTransfer.neg(),
                "CH: cannot withdraw negative"
            );
        }

        if (balanceState.netCashChange != 0 || netCashTransfer != 0) {
            Token memory token = TokenHandler.getToken(balanceState.currencyId);
            balanceState.storedCashBalance = balanceState.storedCashBalance
                .add(balanceState.netCashChange)
                // This will handle transfer fees if they exist
                .add(token.transfer(account, netCashTransfer));
            mustUpdate = true;
        }

        if (netPerpetualTokenTransfer != 0) {
            // Perpetual tokens are within the notional system so we can update balances directly.
            // TODO: we need to update token reward values when we transfer this
            balanceState.storedPerpetualTokenBalance = balanceState.storedPerpetualTokenBalance.add(
                netPerpetualTokenTransfer
            );
            mustUpdate = true;
        }

        if (mustUpdate) setBalanceStorage(account, balanceState);
        if (balanceState.storedCashBalance != 0 || balanceState.storedPerpetualTokenBalance != 0) {
            // Set this to true so that the balances get read next time
            accountContext.activeCurrencies = Bitmap.setBit(
                accountContext.activeCurrencies,
                balanceState.currencyId,
                true
            );
        }
        if (balanceState.storedCashBalance < 0) accountContext.hasDebt = true;
    }

    /**
     * @notice Sets internal balance storage.
     */
    function setBalanceStorage(
        address account,
        BalanceState memory balanceState
    ) private {
        bytes32 slot = keccak256(
            abi.encode(balanceState.currencyId,
                keccak256(abi.encode(account, BALANCE_STORAGE_SLOT))
            )
        );
        require(
            balanceState.storedCashBalance >= type(int128).min
            && balanceState.storedCashBalance <= type(int128).max,
            "CH: cash balance overflow"
        );
        require(
            balanceState.storedPerpetualTokenBalance >= 0
            && balanceState.storedPerpetualTokenBalance <= type(uint128).max,
            "CH: token balance overflow"
        );

        bytes32 data = (
            // Truncate the top half of the signed integer when it is negative
            (bytes32(balanceState.storedCashBalance) & 0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff) |
            (bytes32(uint(balanceState.storedPerpetualTokenBalance)) << 128)
        );

        assembly {
            sstore(slot, data)
        }
    }

    /**
     * @notice Gets internal balance storage, perpetual tokens are stored alongside cash balances
     */
    function getBalanceStorage(address account, uint currencyId) private view returns (int, int) {
        bytes32 slot = keccak256(abi.encode(currencyId, keccak256(abi.encode(account, BALANCE_STORAGE_SLOT))));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        return (
            int(int128(int(data))), // Cash balance
            int(data >> 128) // Perpetual token balance
        );
    }

    /**
     * @notice Builds a currency state object, assumes a valid currency id
     */
    function buildBalanceState(
        address account,
        uint currencyId,
        AccountStorage memory accountContext
    ) internal view returns (BalanceState memory) {
        require(currencyId != 0, "CH: invalid currency id");

        bool isActive = accountContext.activeCurrencies.isBitSet(currencyId);
        if (isActive) {
            // Set the bit to off to mark that we've read the balance
            accountContext.activeCurrencies = Bitmap.setBit(
                accountContext.activeCurrencies,
                currencyId,
                false
            );

            // Storage Read
            (int cashBalance, int tokenBalance) = getBalanceStorage(account, currencyId);
            return BalanceState({
                currencyId: currencyId,
                storedCashBalance: cashBalance,
                storedPerpetualTokenBalance: tokenBalance,
                netCashChange: 0
            });
        }

        return BalanceState({
            currencyId: currencyId,
            storedCashBalance: 0,
            storedPerpetualTokenBalance: 0,
            netCashChange: 0
        });
    }

    /**
     * @notice When doing a free collateral check we must get all active balances, this will
     * fetch any remaining balances and exchange rates that are active on the account.
     */
    function getRemainingActiveBalances(
        address account,
        AccountStorage memory accountContext,
        BalanceState[] memory balanceState
    ) internal view returns (BalanceState[] memory) {
        bytes memory activeCurrencies = accountContext.activeCurrencies;
        uint totalActive = activeCurrencies.totalBitsSet() + balanceState.length;
        BalanceState[] memory newBalanceContext = new BalanceState[](totalActive);
        totalActive = 0;
        uint existingIndex;

        for (uint i; i < activeCurrencies.length; i++) {
            // Scan for the remaining balances in the active currencies list
            if (activeCurrencies[i] == 0x00) continue;

            bytes1 bits = activeCurrencies[i];
            for (uint offset; offset < 8; offset++) {
                if (bits == 0x00) break;

                // The big endian bit is set to one so we get the balance context for this currency id
                if (bits & 0x80 == 0x80) {
                    uint currencyId = (i * 8) + offset + 1;
                    // Insert lower valued currency ids here
                    while (
                        existingIndex < balanceState.length &&
                        balanceState[existingIndex].currencyId < currencyId
                    ) {
                        newBalanceContext[totalActive] = balanceState[existingIndex];
                        totalActive += 1;
                        existingIndex += 1;
                    }

                    // Storage Read
                    newBalanceContext[totalActive] = BalanceHandler.buildBalanceState(
                        account,
                        currencyId,
                        accountContext
                    );
                    totalActive += 1;
                }

                bits = bits << 1;
            }
        }

        // Inserts all remaining currencies
        while (existingIndex < balanceState.length) {
            newBalanceContext[totalActive] = balanceState[existingIndex];
            totalActive += 1;
            existingIndex += 1;
        }

        // This returns an ordered list of balance context by currency id
        return newBalanceContext;
    }
}

contract MockBalanceHandler is StorageLayoutV1 {
    using BalanceHandler for BalanceState;

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

    function finalize(
        BalanceState memory balanceState,
        address account,
        AccountStorage memory accountContext,
        int netCashTransfer,
        int netPerpetualTokenTransfer
    ) public returns (AccountStorage memory) {
        balanceState.finalize(account, accountContext, netCashTransfer, netPerpetualTokenTransfer);

        return accountContext;
    }

    function buildBalanceState(
        address account,
        uint currencyId,
        AccountStorage memory accountContext
    ) public view returns (BalanceState memory, AccountStorage memory) {
        BalanceState memory bs = BalanceHandler.buildBalanceState(account, currencyId, accountContext);

        return (bs, accountContext);
    }

    function getRemainingActiveBalances(
        address account,
        AccountStorage memory accountContext,
        BalanceState[] memory balanceState
    ) public view returns (BalanceState[] memory, AccountStorage memory) {
        BalanceState[] memory bs = BalanceHandler
            .getRemainingActiveBalances(account, accountContext, balanceState);

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