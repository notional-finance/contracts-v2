// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    PortfolioAsset,
    VaultAccount,
    VaultConfig,
    VaultAccountStorage,
    PrimeRate
} from "../global/Types.sol";
import {Constants} from "../global/Constants.sol";
import {LibStorage} from "../global/LibStorage.sol";

import {PrimeRateLib} from "./pCash/PrimeRateLib.sol";
import {SafeInt256} from "../math/SafeInt256.sol";
import {SafeUint256} from "../math/SafeUint256.sol";

import {ITransferEmitter} from "../external/proxies/BaseERC4626Proxy.sol";

/**
 * @notice Controls all event emissions for the protocol so that off chain block explorers can properly
 * index Notional internal accounting. Notional V3 will emit events for these tokens:
 * 
 * ERC20 (emits Transfer via proxy):
 *  - nToken (one nToken contract per currency that has fCash enabled)
 *  - pCash (one pCash contract per listed underlying token)
 *  - pDebt (one pDebt contract per pCash token that allows debt)
 *
 * ERC1155 (emitted from address(this)):
 *  - Positive fCash (represents a positive fCash balance)
 *      ID: [bytes23(0), uint8(0), uint16(currencyId), uint40(maturity), uint8(FCASH_ASSET_TYPE)]
 *  - Negative fCash (v3, represents a negative fCash balance)
 *      ID: [bytes23(0), uint8(1), uint16(currencyId), uint40(maturity), uint8(FCASH_ASSET_TYPE)]
 *  - Vault Share Units (v3, represents a share of a leveraged vault)
 *      ID: [bytes5(0), bytes20(vaultAddress), uint16(currencyId), uint40(maturity), uint8(VAULT_SHARE_ASSET_TYPE)]
 *  - Vault Debt Units (v3, represents debt owed to a leveraged vault)
 *      ID: [bytes5(0), bytes20(vaultAddress), uint16(currencyId), uint40(maturity), uint8(VAULT_DEBT_ASSET_TYPE)]
 *  - Vault Cash Units (v3, represents cash held on a leveraged vault account after liquidation)
 *      ID: [bytes5(0), bytes20(vaultAddress), uint16(currencyId), uint40(maturity), uint8(VAULT_CASH_ASSET_TYPE)]
 *
 *  - NOTE: Liquidity Token ids are not valid within the Notional V3 schema since they are only held by the nToken
 *    and never transferred.
 */
library Emitter {
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 value
    );

    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] values
    );

    uint256 private constant MATURITY_OFFSET        = 8;
    uint256 private constant CURRENCY_OFFSET        = 48;
    uint256 private constant VAULT_ADDRESS_OFFSET   = 64;

    uint256 private constant FCASH_FLAG_OFFSET      = 64;
    uint256 private constant NEGATIVE_FCASH_MASK    = 1 << 64;

    function decodeCurrencyId(uint256 id) internal pure returns (uint16) {
        return uint16(id >> CURRENCY_OFFSET);
    }

    function isfCash(uint256 id) internal pure returns (bool) {
        return uint8(id) == Constants.FCASH_ASSET_TYPE;
    }

    function encodeId(
        uint16 currencyId,
        uint256 maturity,
        uint256 assetType,
        address vaultAddress,
        bool isfCashDebt
    ) internal pure returns (uint256 id) {
        if (assetType == Constants.FCASH_ASSET_TYPE) {
            return encodefCashId(currencyId, maturity, isfCashDebt ? int256(-1) : int256(1));
        } else if (
            assetType == Constants.VAULT_CASH_ASSET_TYPE ||
            assetType == Constants.VAULT_SHARE_ASSET_TYPE ||
            assetType == Constants.VAULT_DEBT_ASSET_TYPE
        ) {
            return _encodeVaultId(vaultAddress, currencyId, maturity, assetType);
        }

        revert();
    }

    function decodeId(uint256 id) internal pure returns (
        uint16 currencyId,
        uint256 maturity,
        uint256 assetType,
        address vaultAddress,
        bool isfCashDebt
    ) {
        assetType   = uint8(id);
        maturity    = uint40(id >> MATURITY_OFFSET);
        currencyId  = uint16(id >> CURRENCY_OFFSET);

        if (assetType == Constants.FCASH_ASSET_TYPE) {
            isfCashDebt = uint8(id >> FCASH_FLAG_OFFSET) == 1;
        } else {
            vaultAddress = address(id >> VAULT_ADDRESS_OFFSET);
        }
    }

    function encodefCashId(uint16 currencyId, uint256 maturity, int256 amount) internal pure returns (uint256 id) {
        require(currencyId <= Constants.MAX_CURRENCIES);
        require(maturity <= type(uint40).max);
        id = _posfCashId(currencyId, maturity);
        if (amount < 0) id = id | NEGATIVE_FCASH_MASK;
    }

    function decodefCashId(uint256 id) internal pure returns (uint16 currencyId, uint256 maturity, bool isfCashDebt) {
        // If the id is not of an fCash asset type, return zeros
        if (uint8(id) != Constants.FCASH_ASSET_TYPE) return (0, 0, false);

        maturity    = uint40(id >> MATURITY_OFFSET);
        currencyId  = uint16(id >> CURRENCY_OFFSET);
        isfCashDebt   = uint8(id >> FCASH_FLAG_OFFSET) == 1;
    }

    function _encodeVaultId(
        address vault,
        uint16 currencyId,
        uint256 maturity,
        uint256 assetType
    ) private pure returns (uint256 id) {
        return uint256(
            (bytes32(uint256(vault)) << VAULT_ADDRESS_OFFSET) |
            (bytes32(uint256(currencyId)) << CURRENCY_OFFSET) |
            (bytes32(maturity) << MATURITY_OFFSET)            |
            (bytes32(assetType))
        );
    }

    function decodeVaultId(uint256 id) internal pure returns (
        uint256 assetType,
        uint16 currencyId,
        uint256 maturity,
        address vaultAddress
    ) {
        assetType   = uint8(id);
        // If the asset type is below this it is not a valid vault asset id
        if (assetType < Constants.VAULT_SHARE_ASSET_TYPE) return (0, 0, 0, address(0));

        maturity    = uint40(id >> MATURITY_OFFSET);
        currencyId  = uint16(id >> CURRENCY_OFFSET);
        vaultAddress = address(id >> VAULT_ADDRESS_OFFSET);
    }


    function _posfCashId(uint16 currencyId, uint256 maturity) internal pure returns (uint256 id) {
        return uint256(
            (bytes32(uint256(currencyId)) << CURRENCY_OFFSET) |
            (bytes32(maturity) << MATURITY_OFFSET)            |
            (bytes32(uint256(Constants.FCASH_ASSET_TYPE)))
        );
    }

    function _getPrimeProxy(bool isDebt, uint16 currencyId) private view returns (ITransferEmitter) {
        return isDebt ? 
            ITransferEmitter(LibStorage.getPDebtAddressStorage()[currencyId]) :
            ITransferEmitter(LibStorage.getPCashAddressStorage()[currencyId]);
    }

    function _fCashPair(
        uint16 currencyId, uint256 maturity, int256 amount
    ) private pure returns (uint256[] memory, uint256[] memory) {
        uint256[] memory ids = new uint256[](2);
        uint256 id = _posfCashId(currencyId, maturity);
        ids[0] = id;
        ids[1] = id | NEGATIVE_FCASH_MASK;

        uint256[] memory values = new uint256[](2);
        values[0] = uint256(amount.abs());
        values[1] = uint256(amount.abs());

        return (ids, values);
    }

    /// @notice Emits a pair of fCash mints. fCash is only ever created or destroyed via these pairs and then
    /// the positive side is bought or sold.
    function emitChangefCashLiquidity(
        address account, uint16 currencyId, uint256 maturity, int256 netDebtChange
    ) internal {
        (uint256[] memory ids, uint256[] memory values) = _fCashPair(currencyId, maturity, netDebtChange);
        address from; address to;
        if (netDebtChange < 0) from = account; // burning
        else to = account; // minting
        emit TransferBatch(msg.sender, from, to, ids, values);
    }

    /// @notice Transfers positive fCash between accounts
    function emitTransferfCash(
        address from, address to, uint16 currencyId, uint256 maturity, int256 amount
    ) internal {
        if (amount == 0) return;
        uint256 id = _posfCashId(currencyId, maturity);
        // If the amount is negative, then swap the direction of the transfer. We only ever emit
        // transfers of positive fCash. Negative fCash is minted on an account and never transferred.
        if (amount < 0) (from, to) = (to, from);

        emit TransferSingle(msg.sender, from, to, id, uint256(amount.abs()));
    }

    function emitBatchTransferfCash(
        address from, address to, PortfolioAsset[] memory assets
    ) internal {
        uint256 len = assets.length;
        // Emit single events since it's unknown if all of the notional values are positive or negative.
        for (uint256 i; i < len; i++) {
            emitTransferfCash(from, to, assets[i].currencyId, assets[i].maturity, assets[i].notional);
        }
    }

    /// @notice When fCash is settled, cash or debt is transferred from the "settlement reserve" to the account
    /// and the settled fCash is burned.
    function emitSettlefCash(
        address account, uint16 currencyId, uint256 maturity, int256 fCashSettled, int256 pCashOrDebtValue
    ) internal {
        // Settlement is the only time when negative fCash is burned directly without destroying the
        // opposing positive fCash pair.
        uint256 id = _posfCashId(currencyId, maturity);
        if (fCashSettled < 0) id = id | NEGATIVE_FCASH_MASK;
        emit TransferSingle(msg.sender, account, address(0), id, uint256(fCashSettled.abs()));

        // NOTE: zero values will emit a pCash event
        ITransferEmitter proxy = _getPrimeProxy(pCashOrDebtValue < 0, currencyId);
        proxy.emitTransfer(Constants.SETTLEMENT_RESERVE, account, uint256(pCashOrDebtValue.abs()));
    }

    /// @notice Emits events to reconcile off chain accounting for the edge condition when
    /// leveraged vaults lend at zero interest.
    function emitSettlefCashDebtInReserve(
        uint16 currencyId,
        uint256 maturity,
        int256 fCashDebtInReserve,
        int256 settledPrimeCash,
        int256 excessCash
    ) internal {
        uint256 id = _posfCashId(currencyId, maturity) | NEGATIVE_FCASH_MASK;
        emit TransferSingle(msg.sender, Constants.SETTLEMENT_RESERVE, address(0), id, uint256(fCashDebtInReserve.abs()));
        // The settled prime debt doesn't exist in this case since we don't add the debt to the
        // total prime debt so we just "burn" the prime cash that only exists in an off chain accounting context.
        // TODO: may want to emit a repay event here instead...
        emitMintOrBurnPrimeCash(Constants.SETTLEMENT_RESERVE, currencyId, settledPrimeCash);
        if (excessCash > 0) {
            // Any excess prime cash in reserve is "transferred" to the fee reserve
            emitTransferPrimeCash(Constants.SETTLEMENT_RESERVE, Constants.FEE_RESERVE, currencyId, excessCash);
        }
    }

    /// @notice During an fCash trade, cash is transferred between the account and then nToken. When borrowing,
    /// cash is transferred from the nToken to the account. During lending, the opposite happens. The fee reserve
    /// always accrues a positive amount of cash.
    function emitfCashMarketTrade(
        address account,
        uint16 currencyId,
        uint256 maturity,
        int256 fCashPurchased,
        int256 cashToAccount,
        int256 cashToReserve
    ) internal {
        ITransferEmitter cashProxy = ITransferEmitter(LibStorage.getPCashAddressStorage()[currencyId]);
        address nToken = LibStorage.getNTokenAddressStorage()[currencyId];
        // If account == nToken then this is a lending transaction when the account is
        // over leveraged. Still emit the transfer so we can record how much the lending cost and how
        // much fCash was purchased.

        // Do this calculation so it properly represents that the account is paying the fee to the
        // reserve. When borrowing, the account will receive the full cash balance and then transfer
        // some amount to the reserve. When lending, the account will transfer the cash to reserve and
        // the remainder will be transferred to the nToken.
        int256 accountToNToken = cashToAccount.add(cashToReserve);
        cashProxy.emitfCashTradeTransfers(account, nToken, accountToNToken, cashToReserve.toUint());

        // When lending (fCashPurchased > 0), the nToken transfers positive fCash to the
        // account. When the borrowing (fCashPurchased < 0), the account transfers positive fCash to the
        // nToken. emitTransferfCash will flip the from and to accordingly.
        // TODO: this should emit a batch of cash and fCash transfers
        emitTransferfCash(nToken, account, currencyId, maturity, fCashPurchased);
    }

    /// @notice When underlying tokens are deposited, prime cash is minted. When underlying tokens are
    /// withdrawn, prime cash is burned.
    function emitMintOrBurnPrimeCash(
        address account, uint16 currencyId, int256 netPrimeCash
    ) internal {
        ITransferEmitter cashProxy = ITransferEmitter(LibStorage.getPCashAddressStorage()[currencyId]);
        cashProxy.emitMintOrBurn(account, netPrimeCash);
    }

    function emitTransferPrimeCash(
        address from, address to, uint16 currencyId, int256 primeCashTransfer
    ) internal {
        ITransferEmitter cashProxy = ITransferEmitter(LibStorage.getPCashAddressStorage()[currencyId]);
        // This can happen during fCash liquidation where the liquidator receives cash for negative fCash
        if (primeCashTransfer < 0) (to, from) = (from, to);
        cashProxy.emitTransfer(from, to, uint256(primeCashTransfer.abs()));
    }

    function emitTransferNToken(
        address from, address to, uint16 currencyId, int256 netNTokenTransfer
    ) internal {
        address nToken = LibStorage.getNTokenAddressStorage()[currencyId];
        // No scenario where this occurs, but have it here just in case
        if (netNTokenTransfer < 0) (to, from) = (from, to);
        // Legacy nToken contracts do not have an emit method
        try ITransferEmitter(nToken).emitTransfer(from, to, uint256(netNTokenTransfer.abs())) {} catch {
            // TODO: emit some other equivalent event here...
        }
    }

    /// @notice When prime debt is created, an offsetting pair of prime cash and prime debt tokens are
    /// created (similar to fCash liquidity) and the prime cash tokens are burned (withdrawn) or transferred
    /// in exchange for nTokens or fCash. The opposite occurs when prime debt is repaid. Prime cash is burned
    /// in order to repay prime debt.
    function emitBorrowOrRepayPrimeDebt(
        address account, uint16 currencyId, int256 netPrimeSupplyChange, int256 netPrimeDebtChange
    ) internal {
        ITransferEmitter cashProxy = ITransferEmitter(LibStorage.getPCashAddressStorage()[currencyId]);
        ITransferEmitter debtProxy = ITransferEmitter(LibStorage.getPDebtAddressStorage()[currencyId]);
        debtProxy.emitMintOrBurn(account, netPrimeDebtChange);
        cashProxy.emitMintOrBurn(account, netPrimeSupplyChange);
    }

    /// @notice Some amount of prime cash is deposited in order to mint nTokens.
    function emitNTokenMint(
        address account, address nToken, uint16 currencyId, int256 primeCashDeposit, int256 tokensToMint
    ) internal {
        ITransferEmitter cashProxy = ITransferEmitter(LibStorage.getPCashAddressStorage()[currencyId]);
        if (tokensToMint > 0 && primeCashDeposit > 0) {
            cashProxy.emitTransfer(account, nToken, uint256(primeCashDeposit));
            // Legacy nToken contracts do not have an emit method
            try ITransferEmitter(nToken).emitMintOrBurn(account, tokensToMint) {} catch {}
        }
    }

    /// @notice Some amount of prime cash is transferred to the account in exchange for nTokens burned.
    /// fCash may also be transferred to the account but that is handled in a different method.
    function emitNTokenBurn(
        address account, uint16 currencyId, int256 primeCashRedeemed, int256 tokensToBurn
    ) internal {
        ITransferEmitter cashProxy = ITransferEmitter(LibStorage.getPCashAddressStorage()[currencyId]);
        address nToken = LibStorage.getNTokenAddressStorage()[currencyId];

        if (primeCashRedeemed > 0 && tokensToBurn > 0) {
            cashProxy.emitTransfer(nToken, account, uint256(primeCashRedeemed));
            // Legacy nToken contracts do not have an emit method
            try ITransferEmitter(nToken).emitMintOrBurn(account, tokensToBurn.neg()) {} catch {}
        }
    }

    function emitVaultFeeTransfers(
        address vault, uint16 currencyId, int256 nTokenFee, int256 reserveFee
    ) internal{
        ITransferEmitter cashProxy = ITransferEmitter(LibStorage.getPCashAddressStorage()[currencyId]);
        address nToken = LibStorage.getNTokenAddressStorage()[currencyId];
        // These are emitted in the reverse order from the fCash trade transfers so that we can identify it as
        // vault fee transfers off chain.
        cashProxy.emitTransfer(vault, Constants.FEE_RESERVE, reserveFee.toUint());
        cashProxy.emitTransfer(vault, address(nToken), nTokenFee.toUint());
    }

    /// @notice Detects changes to a vault account and properly emits vault debt, vault shares and vault cash events.
    function emitVaultAccountChanges(
        VaultAccount memory vaultAccount,
        VaultConfig memory vaultConfig,
        VaultAccountStorage memory prior,
        uint256 newDebtStorageValue
    ) internal {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory values = new uint256[](2);
        uint256 baseId = _encodeVaultId(vaultConfig.vault, vaultConfig.borrowCurrencyId, prior.maturity, 0);
        ids[0] = baseId | Constants.VAULT_DEBT_ASSET_TYPE;
        ids[1] = baseId | Constants.VAULT_SHARE_ASSET_TYPE;

        if (vaultAccount.maturity == 0 || (prior.maturity != 0 && prior.maturity != vaultAccount.maturity)) {
            // Account has been closed, settled or rolled to a new maturity. Emit burn events for the prior maturity's data.
            values[0] = prior.accountDebt;
            values[1] = prior.vaultShares;
            emit TransferBatch(msg.sender, vaultAccount.account, address(0), ids, values);
        } else if (vaultAccount.maturity == prior.maturity) {
            // Vault account is in the same maturity, either an entry or an exit has occurred. In an
            // entry, the vault debt must stay the same or increase. Vault shares must stay the same or increase.
            // In an exit, the vault debt must stay the same or decrease. Vault shares must stay the same or decrease.
            bool isBurn = newDebtStorageValue < prior.accountDebt || vaultAccount.vaultShares < prior.vaultShares;
            address from; address to;
            if (isBurn) {
                values[0] = uint256(prior.accountDebt).sub(newDebtStorageValue);
                values[1] = uint256(prior.vaultShares).sub(vaultAccount.vaultShares);
                from = vaultAccount.account;
                to = address(0);
            } else {
                values[0] = newDebtStorageValue.sub(prior.accountDebt);
                values[1] = vaultAccount.vaultShares.sub(prior.vaultShares);
                from = address(0);
                to = vaultAccount.account;
            }
            emit TransferBatch(msg.sender, from, to, ids, values);
        }

        if (vaultAccount.maturity != 0 && prior.maturity != vaultAccount.maturity) {
            // Need to mint the shares for the new vault maturity, this may be a new entrant into
            // the vault or the vault account rolling to a new maturity
            baseId = _encodeVaultId(vaultConfig.vault, vaultConfig.borrowCurrencyId, vaultAccount.maturity, 0);
            ids[0] = baseId | Constants.VAULT_DEBT_ASSET_TYPE;
            ids[1] = baseId | Constants.VAULT_SHARE_ASSET_TYPE;
            values[0] = newDebtStorageValue;
            values[1] = vaultAccount.vaultShares;
            emit TransferBatch(msg.sender, address(0), vaultAccount.account, ids, values);
        }

        if (prior.primaryCash != 0) {
            // Cash must always be burned in this method from the prior maturity
            emit TransferSingle(
                msg.sender,
                vaultAccount.account,
                address(0),
                baseId | Constants.VAULT_CASH_ASSET_TYPE,
                prior.primaryCash
            );
        }

    }

    /// @notice Emits events during a vault deleverage, where a vault account receives cash and loses
    /// vault shares as a result.
    function emitVaultDeleverage(
        address liquidator,
        address account,
        address vault,
        uint16 currencyId,
        uint256 maturity,
        int256 depositAmountPrimeCash,
        uint256 vaultSharesToLiquidator,
        PrimeRate memory pr
    ) internal {
        // Liquidator transfer prime cash to vault
        emitTransferPrimeCash(liquidator, vault, currencyId, depositAmountPrimeCash);
        uint256 baseId = _encodeVaultId(vault, currencyId, maturity, 0);
        
        // Mints vault cash to the account in the same amount as prime cash if it is
        // an fCash maturity
        if (maturity == Constants.PRIME_CASH_VAULT_MATURITY) {
            // Convert this to prime debt basis
            int256 primeDebtStorage = PrimeRateLib.convertToStorageValue(pr, depositAmountPrimeCash.neg()).neg();
            if (primeDebtStorage == -1) primeDebtStorage = 0;

            emit TransferSingle(
                msg.sender,
                account,
                address(0),
                baseId | Constants.VAULT_DEBT_ASSET_TYPE,
                primeDebtStorage.toUint()
            );
        } else {
            emit TransferSingle(
                msg.sender,
                address(0),
                account,
                baseId | Constants.VAULT_CASH_ASSET_TYPE,
                depositAmountPrimeCash.toUint()
            );
        }

        // Transfer vault shares to the liquidator
        emit TransferSingle(
            msg.sender, account, liquidator, baseId | Constants.VAULT_SHARE_ASSET_TYPE, vaultSharesToLiquidator
        );
    }

    /// @notice Emits events for primary cash burned on a vault account.
    function emitVaultAccountCashBurn(
        address account,
        address vault,
        uint16 currencyId,
        uint256 maturity,
        int256 fCash,
        int256 vaultCash
    ) internal {
        uint256 baseId = _encodeVaultId(vault, currencyId, maturity, 0);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory values = new uint256[](2);
        ids[0] = baseId | Constants.VAULT_DEBT_ASSET_TYPE;
        ids[1] = baseId | Constants.VAULT_CASH_ASSET_TYPE;
        values[0] = fCash.toUint();
        values[1] = vaultCash.toUint();
        emit TransferBatch(msg.sender, account, address(0), ids, values);
    }

    /// @notice A set of spurious events to record a direct transfer between vaults and an account
    /// during entering and exiting vaults.
    function emitVaultMintTransferBurn(
        address minter, address burner, uint16 currencyId, uint256 mintAmount, uint256 transferAndBurnAmount
    ) internal{
        ITransferEmitter cashProxy = ITransferEmitter(LibStorage.getPCashAddressStorage()[currencyId]);
        // During vault entry, the account (minter) will deposit mint amount and transfer the
        // entirety of it to the vault (burner) who will then withdraw it all into the strategy (burn).

        // During vault exit, the vault (minter) will "receive" sufficient cash to repay debt and
        // some additional profits to the account. The vault will "transferAndBurn" the profits
        // to the account. The cash for repayment to Notional will be transferred into fCash markets
        // or used to burn prime supply debt. These events will be emitted separately.

        cashProxy.emitMintTransferBurn(minter, burner, mintAmount, transferAndBurnAmount);
    }

    /// @notice Emits an event where the vault burns its secondary cash balances.
    function emitVaultBurnSecondaryCash(
        address account,
        VaultConfig memory vaultConfig,
        uint256 maturity,
        int256 primeCashRefundOne,
        int256 primeCashRefundTwo
    ) internal {
        if (primeCashRefundOne == 0 && primeCashRefundTwo == 0) return;

        address vault = vaultConfig.vault;
        if (primeCashRefundOne > 0 && primeCashRefundTwo > 0) {
            uint256[] memory ids = new uint256[](2);
            uint256[] memory values = new uint256[](2);
            ids[0] = _encodeVaultId(vault, vaultConfig.secondaryBorrowCurrencies[0], maturity, Constants.VAULT_CASH_ASSET_TYPE);
            ids[1] = _encodeVaultId(vault, vaultConfig.secondaryBorrowCurrencies[1], maturity, Constants.VAULT_CASH_ASSET_TYPE);
            values[0] = primeCashRefundOne.toUint();
            values[1] = primeCashRefundTwo.toUint();
            // Burn both cash balances if they are non zero
            emit TransferBatch(msg.sender, account, address(0), ids, values);
        } else {
            uint256 id = primeCashRefundOne > 0 ? 
                _encodeVaultId(vault, vaultConfig.secondaryBorrowCurrencies[0], maturity, Constants.VAULT_CASH_ASSET_TYPE) :
                _encodeVaultId(vault, vaultConfig.secondaryBorrowCurrencies[1], maturity, Constants.VAULT_CASH_ASSET_TYPE);
            uint256 value = primeCashRefundOne > 0 ?  primeCashRefundOne.toUint() : primeCashRefundTwo.toUint();

            // Just burn the non zero balance
            emit TransferSingle(msg.sender, account, address(0), id, value);
        }
    }

    /// @notice Emits an event where the vault borrows or repays secondary debt
    function emitVaultSecondaryDebt(
        address account,
        address vault,
        uint16 currencyId,
        uint256 maturity,
        int256 vaultDebtAmount
    ) internal {
        address from;
        address to;
        uint256 id = _encodeVaultId(vault, currencyId, maturity, Constants.VAULT_DEBT_ASSET_TYPE);

        if (vaultDebtAmount > 0) {
            // Debt amounts are negative, burning when positive
            from = account; to = address(0);
         } else {
            // Minting when negative
            from = address(0); to = account;
         }

        emit TransferSingle(msg.sender, from, to, id, uint256(vaultDebtAmount.abs()));
    }
}