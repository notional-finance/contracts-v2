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
    int storedCapitalDeposit;
    int netCashChange;
    int netCashTransfer;
    int netPerpetualTokenTransfer;
    int netCapitalDeposit;
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
        AccountStorage memory accountContext
    ) internal {
        bool mustUpdate;
        if (balanceState.netCashTransfer < 0) {
            // Transfer fees will always reduce netCashTransfer so the receiving account will receive less
            // but the Notional system will account for the total net cash transfer out here
            require(
                balanceState.storedCashBalance.add(balanceState.netCashChange) >= balanceState.netCashTransfer.neg(),
                "CH: cannot withdraw negative"
            );
        }

        if (balanceState.netPerpetualTokenTransfer < 0) {
            require(
                balanceState.storedPerpetualTokenBalance >= balanceState.netPerpetualTokenTransfer.neg(),
                "CH: cannot withdraw negative"
            );
        }

        if (balanceState.netCashChange != 0 || balanceState.netCashTransfer != 0) {
            Token memory token = TokenHandler.getToken(balanceState.currencyId);
            balanceState.storedCashBalance = balanceState.storedCashBalance
                .add(balanceState.netCashChange)
                // This will handle transfer fees if they exist
                .add(token.transfer(account, balanceState.netCashTransfer));
            mustUpdate = true;
        }

        if (balanceState.netPerpetualTokenTransfer != 0) {
            // Perpetual tokens are within the notional system so we can update balances directly.
            // TODO: need to ensure that perpetual tokens cannot be transferred to the perpetual token
            // address, not sure where that logic lives
            balanceState.storedPerpetualTokenBalance = balanceState.storedPerpetualTokenBalance.add(
                balanceState.netPerpetualTokenTransfer
            );
            mustUpdate = true;
        }

        if (balanceState.netCapitalDeposit != 0) {
            // TODO: need to ensure that perpetual tokens do not have their capital deposit account
            // updated
            balanceState.storedCapitalDeposit = balanceState.storedCapitalDeposit.add(
                balanceState.netCapitalDeposit
            );
            mustUpdate = true;
            
            incrementGlobalCapitalDeposit(balanceState.currencyId, balanceState.netCapitalDeposit);
        }

        if (mustUpdate) setBalanceStorage(account, balanceState);
        if (balanceState.storedCashBalance != 0 
            || balanceState.storedPerpetualTokenBalance != 0
            || balanceState.storedCapitalDeposit != 0
        ) {
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
     * @notice Special method for setting balance storage for perp token, during initialize
     * markets to reduce code size.
     */
    function setBalanceStorageForPerpToken(
        BalanceState memory balanceState,
        address perpToken
    ) internal {
        // These factors must always be zero for the perpetual token account
        require(balanceState.storedPerpetualTokenBalance == 0);
        require(balanceState.storedCapitalDeposit == 0);
        balanceState.storedCashBalance = balanceState.storedCashBalance.add(balanceState.netCashChange);

        // Perpetual token can never have a negative cash balance
        require(balanceState.storedCashBalance >= 0);

        setBalanceStorage(perpToken, balanceState);
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
            balanceState.storedCashBalance >= type(int88).min
            && balanceState.storedCashBalance <= type(int88).max,
            "CH: cash balance overflow"
        );

        require(
            balanceState.storedCapitalDeposit >= type(int88).min
            && balanceState.storedCapitalDeposit <= type(int88).max,
            "CH: capital deposit overflow"
        );

        require(
            balanceState.storedPerpetualTokenBalance >= 0
            && balanceState.storedPerpetualTokenBalance <= type(uint80).max,
            "CH: token balance overflow"
        );

        bytes32 data = (
            // Truncate the higher bits of the signed integer when it is negative
            (bytes32(balanceState.storedCashBalance) & 0x000000000000000000000000000000000000000000ffffffffffffffffffffff) |
            (bytes32(uint(balanceState.storedPerpetualTokenBalance)) << 88) |
            // No need to truncate higher bits, this is already shifted
            (bytes32(balanceState.storedCapitalDeposit) << 168)
        );

        assembly {
            sstore(slot, data)
        }
    }

    /**
     * @notice Increment the global capital deposit
     */
    function incrementGlobalCapitalDeposit(
        uint currencyId,
        int netCapitalDeposit
    ) private {
        bytes32 slot = keccak256(abi.encode(currencyId, "currency.incentives"));
        bytes32 data;

        assembly { data := sload(slot) }
        // Global capital deposit cannot go below zero
        int globalCapitalDeposit = int(uint128(uint(data)));
        globalCapitalDeposit = globalCapitalDeposit.add(netCapitalDeposit);
        require(
            globalCapitalDeposit >= 0 && globalCapitalDeposit <= type(uint128).max,
            "B: global deposit overflow"
        );

        data = (
            data & 0xffffffffffffffffffffffffffffffff00000000000000000000000000000000 |
            // Global capital deposit cannot be negative so the top bits will be zero
            // TODO: validate this statement
            bytes32(globalCapitalDeposit) & 0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff
        );

        assembly { sstore(slot, data) }
    }

    /**
     * @notice Get the global incentive data for minting incentives
     */
    function getCurrencyIncentiveData(
        uint currencyId
    ) internal view returns (uint, uint) {
        bytes32 slot = keccak256(abi.encode(currencyId, "currency.incentives"));
        bytes32 data;
        assembly { data := sload(slot) }

        uint globalCapitalDeposit = uint(uint128(uint(data)));
        uint tokenEmissionRate = uint(uint32(uint(data >> 128)));

        return (globalCapitalDeposit, tokenEmissionRate);
    }

    /**
     * @notice Gets internal balance storage, perpetual tokens are stored alongside cash balances
     */
    function getBalanceStorage(address account, uint currencyId) private view returns (int, int, int) {
        bytes32 slot = keccak256(abi.encode(currencyId, keccak256(abi.encode(account, BALANCE_STORAGE_SLOT))));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        return (
            int(int88(int(data))),   // Cash balance
            int(uint80(uint(data >> 88))), // Perpetual token balance
            int(int88(int(data >> 168)))  // netCapitalDeposit
        );
    }

    /**
     * @notice Builds a currency state object, assumes a valid currency id
     */
    function buildBalanceState(
        address account,
        uint currencyId,
        bytes memory activeCurrencies
    ) internal view returns (BalanceState memory) {
        require(currencyId != 0, "CH: invalid currency id");

        bool isActive = activeCurrencies.isBitSet(currencyId);
        if (isActive) {
            // Set the bit to off to mark that we've read the balance
            activeCurrencies = Bitmap.setBit(
                activeCurrencies,
                currencyId,
                false
            );

            // Storage Read
            (int cashBalance, int tokenBalance, int storedCapitalDeposit) = getBalanceStorage(account, currencyId);
            return BalanceState({
                currencyId: currencyId,
                storedCashBalance: cashBalance,
                storedPerpetualTokenBalance: tokenBalance,
                storedCapitalDeposit: storedCapitalDeposit,
                netCashChange: 0,
                netCashTransfer: 0,
                netPerpetualTokenTransfer: 0,
                netCapitalDeposit: 0
            });
        }

        return BalanceState({
            currencyId: currencyId,
            storedCashBalance: 0,
            storedPerpetualTokenBalance: 0,
            storedCapitalDeposit: 0,
            netCashChange: 0,
            netCashTransfer: 0,
            netPerpetualTokenTransfer: 0,
            netCapitalDeposit: 0
        });
    }

    /**
     * @notice When doing a free collateral check we must get all active balances, this will
     * fetch any remaining balances and exchange rates that are active on the account.
     */
    function getRemainingActiveBalances(
        address account,
        bytes memory activeCurrencies,
        BalanceState[] memory balanceState
    ) internal view returns (BalanceState[] memory) {
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
                        activeCurrencies
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

    /**
     * @notice Iterates over an array of balances and returns the total incentives to mint.
     */
    function calculateIncentivesToMint(
        BalanceState[] memory balanceState,
        AccountStorage memory accountContext,
        uint blockTime
    ) internal view returns (uint) {
        // We must mint incentives for all currencies at the same time since we set a single timestamp
        // for when the account last minted incentives.
        if (accountContext.hasIdiosyncraticfCash) return 0;
        require(accountContext.activeCurrencies.totalBitsSet() == 0, "B: must mint currencies");
        require(accountContext.lastMintTime != 0, "B: last mint time zero");
        require(accountContext.lastMintTime < blockTime, "B: last mint time overflow");

        uint timeSinceLastMint = blockTime - accountContext.lastMintTime;
        uint tokensToTransfer;
        for (uint i; i < balanceState.length; i++) {
            // Cannot mint incentives if there is a negative capital deposit. Also we explicitly do not include
            // net capital deposit (the current amount to change) because an account may manipulate this amount to
            // increase their capital deposited figure using flash loans.
            if (balanceState[i].storedCapitalDeposit <= 0) continue;

            (uint globalCapitalDeposit, uint tokenEmissionRate) = getCurrencyIncentiveData(balanceState[i].currencyId);
            if (globalCapitalDeposit == 0 || tokenEmissionRate == 0) continue;

            tokensToTransfer = tokensToTransfer.add(
                // We know that this must be positive
                uint(balanceState[i].storedCapitalDeposit)
                    .mul(timeSinceLastMint)
                    .mul(tokenEmissionRate)
                    .div(CashGroup.YEAR)
                    // tokenEmissionRate is denominated in 1e9
                    .div(uint(TokenHandler.INTERNAL_TOKEN_PRECISION))
                    .div(globalCapitalDeposit)
            );
        }

        require(blockTime <= type(uint32).max, "B: block time overflow");
        accountContext.lastMintTime = uint32(blockTime);
        return tokensToTransfer;
    }

    /**
     * @notice Incentives must be minted before we store netCapitalDeposit changes.
     */
    function mintIncentives(
        BalanceState[] memory balanceState,
        AccountStorage memory accountContext,
        address account,
        uint blockTime
    ) internal returns (uint) {
        // Accounts that have idiosyncratic fcash cannot mint incentives
        if (accountContext.hasIdiosyncraticfCash) return 0;

        uint tokensToTransfer = calculateIncentivesToMint(balanceState, accountContext, blockTime);
        TokenHandler.transferIncentive(account, tokensToTransfer);
        return tokensToTransfer;
    }

}
