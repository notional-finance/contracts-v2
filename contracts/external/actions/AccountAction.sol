// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    BalanceState,
    AccountContext,
    PortfolioAsset,
    PrimeRate
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {TransferAssets} from "../../internal/portfolio/TransferAssets.sol";
import {BalanceHandler} from "../../internal/balances/BalanceHandler.sol";
import {nTokenHandler} from "../../internal/nToken/nTokenHandler.sol";
import {PrimeRateLib} from "../../internal/pCash/PrimeRateLib.sol";
import {AccountContextHandler} from "../../internal/AccountContextHandler.sol";

import {ActionGuards} from "./ActionGuards.sol";
import {nTokenRedeemAction} from "./nTokenRedeemAction.sol";
import {SettleAssetsExternal} from "../SettleAssetsExternal.sol";
import {FreeCollateralExternal} from "../FreeCollateralExternal.sol";
import {MigrateIncentives} from "../MigrateIncentives.sol";

contract AccountAction is ActionGuards {
    using BalanceHandler for BalanceState;
    using AccountContextHandler for AccountContext;
    using PrimeRateLib for PrimeRate;
    using SafeInt256 for int256;

    /// @notice A per account setting that allows it to borrow prime cash (i.e. incur negative cash)
    /// as a result of account initiated actions. Accounts can still incur negative cash as a result of
    /// fCash settlement regardless of this setting.
    /// @param allowPrimeBorrow true if the account can borrow prime cash
    /// @dev emit:AccountSettled emit:AccountContextUpdate
    /// @dev auth:msg.sender
    function enablePrimeBorrow(bool allowPrimeBorrow) external {
        require(msg.sender != address(this)); // dev: no internal call
        requireValidAccount(msg.sender);
        (AccountContext memory accountContext, /* didSettle */) = _settleAccountIfRequired(msg.sender);
        accountContext.allowPrimeBorrow = allowPrimeBorrow;
        accountContext.setAccountContext(msg.sender);
    }

    /// @notice Enables a bitmap currency for msg.sender, account cannot have any assets when this call
    /// occurs. Will revert if the account already has a bitmap currency set.
    /// @param currencyId the currency to enable the bitmap for.
    /// @dev emit:AccountSettled emit:AccountContextUpdate
    /// @dev auth:msg.sender
    function enableBitmapCurrency(uint16 currencyId) external {
        require(msg.sender != address(this)); // dev: no internal call to enableBitmapCurrency
        require(currencyId <= maxCurrencyId); // dev: invalid currency id
        address account = msg.sender;
        (AccountContext memory accountContext, /* didSettle */) = _settleAccountIfRequired(account);
        accountContext.enableBitmapForAccount(currencyId, block.timestamp);
        accountContext.setAccountContext(account);
    }

    /// @notice Method for manually settling an account, generally should not be called because other
    /// methods will check if an account needs to be settled automatically. If a bitmap account has debt
    /// and is settled via this method, the hasDebt flag will not be cleared until a free collateral check
    /// is performed on the account.
    /// @param account the account to settle
    /// @dev emit:AccountSettled emit:AccountContextUpdate
    /// @dev auth:none
    /// @return returns true if account has been settled
    function settleAccount(address account) external returns (bool) {
        requireValidAccount(account);
        (AccountContext memory accountContext, bool didSettle) = _settleAccountIfRequired(account);
        if (didSettle) accountContext.setAccountContext(account);
        return didSettle;
    }

    /// @notice Deposits and wraps the underlying token for a particular cToken. Does not settle assets or check free
    /// collateral, idea is to be as gas efficient as possible during potential liquidation events.
    /// @param account the account to deposit into
    /// @param currencyId currency id of the asset token that wraps this underlying
    /// @param amountExternalPrecision the amount of underlying tokens in its native decimal precision
    /// (i.e. 18 decimals for DAI or 6 decimals for USDC). This will be converted to 8 decimals during transfer.
    /// @return asset tokens minted and deposited to the account in internal decimals (8)
    /// @dev emit:CashBalanceChange emit:AccountContextUpdate
    /// @dev auth:none
    function depositUnderlyingToken(
        address account,
        uint16 currencyId,
        uint256 amountExternalPrecision
    ) external payable nonReentrant returns (uint256) {
        require(msg.sender != address(this)); // dev: no internal call to deposit underlying
        requireValidAccount(account);

        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState memory balanceState;
        balanceState.loadBalanceState(account, currencyId, accountContext);

        // NOTE: using msg.sender here allows for a different sender to deposit tokens into
        // the specified account. This may be useful for on-demand collateral top ups from a
        // third party.
        int256 primeCashReceived = balanceState.depositUnderlyingToken(
            msg.sender,
            SafeInt256.toInt(amountExternalPrecision),
            false // there should never be excess ETH here by definition
        );

        require(primeCashReceived > 0); // dev: asset tokens negative or zero

        balanceState.finalizeNoWithdraw(account, accountContext);
        accountContext.setAccountContext(account);

        // Check the supply cap after all balances have been finalized
        balanceState.primeRate.checkSupplyCap(currencyId);

        // NOTE: no free collateral checks required for depositing
        return primeCashReceived.toUint();
    }

    /// @notice DEPRECATED: deposits deprecated cTokens tokens as collateral into an account that
    /// were listed prior to the migration to prime cash. Future listed tokens will not have asset
    /// tokens and will revert in this method.
    /// @param account the account to deposit into
    /// @param currencyId currency id of the asset token
    /// @param amountExternalPrecision the amount of asset tokens in its native decimal precision
    /// (i.e. 8 decimals for cTokens).
    /// @return asset tokens minted and deposited to the account in internal decimals (8)
    /// @dev emit:CashBalanceChange emit:AccountContextUpdate
    /// @dev auth:none
    function depositAssetToken(
        address account,
        uint16 currencyId,
        uint256 amountExternalPrecision
    ) external nonReentrant returns (uint256) {
        require(msg.sender != address(this)); // dev: no internal call to deposit asset
        requireValidAccount(account);

        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState memory balanceState;
        balanceState.loadBalanceState(account, currencyId, accountContext);

        // Int conversion overflow check done inside this method call. msg.sender
        // is used as the account in deposit to allow for other accounts to deposit
        // on behalf of the given account. This always does an immediate transfer
        // and marks the net prime cash change on the balance state.
        int256 primeCashReceived = balanceState.depositDeprecatedAssetToken(
            msg.sender,
            SafeInt256.toInt(amountExternalPrecision)
        );

        require(primeCashReceived > 0); // dev: asset tokens negative or zero

        balanceState.finalizeNoWithdraw(account, accountContext);
        accountContext.setAccountContext(account);

        // Check the supply cap after all balances have been finalized
        balanceState.primeRate.checkSupplyCap(currencyId);

        // NOTE: no free collateral checks required for depositing
        return primeCashReceived.toUint();
    }

    /// @notice Withdraws balances from Notional, may also redeem to underlying tokens on user request. Will settle
    /// and do free collateral checks if required. Can only be called by msg.sender, operators who want to withdraw for
    /// an account must do an authenticated call via ERC1155Action `safeTransferFrom` or `safeBatchTransferFrom`
    /// @param currencyId currency id of the asset token
    /// @param amountInternalPrecision the amount of cash balance in internal 8 decimal precision to withdraw,
    /// this is be denominated in prime cash. If set to uint88 max, will withdraw an entire cash balance.
    /// @param redeemToUnderlying DEPRECATED except for ETH balances. Prior to the prime cash upgrade, accounts could withdraw
    /// cTokens directly. However, post prime cash migration this is no longer the case. If withdrawing ETH, setting redeemToUnderlying
    /// to false will redeem ETH as WETH.
    /// @dev emit:CashBalanceChange emit:AccountContextUpdate
    /// @dev auth:msg.sender
    /// @return the amount of tokens received by the account denominated in the destination token precision (if
    // redeeming to underlying the amount will be the underlying amount received in that token's native precision)
    function withdraw(
        uint16 currencyId,
        uint88 amountInternalPrecision,
        bool redeemToUnderlying
    ) external nonReentrant returns (uint256) {
        if (currencyId != Constants.ETH_CURRENCY_ID) {
            require(redeemToUnderlying, "Deprecated: Redeem to cToken");
        }
        // This happens before reading the balance state to get the most up to date cash balance
        (AccountContext memory accountContext, /* didSettle */) = _settleAccountIfRequired(msg.sender);

        BalanceState memory balanceState;
        balanceState.loadBalanceState(msg.sender, currencyId, accountContext);
        if (amountInternalPrecision == type(uint88).max) {
            // if set to uint88 max, withdraw the full stored balance. This feature only
            // works if there is a positive balance
            require(balanceState.storedCashBalance > 0);
            balanceState.primeCashWithdraw = balanceState.storedCashBalance.neg();
        } else {
        // Overflow is not possible due to uint88
            balanceState.primeCashWithdraw = int256(amountInternalPrecision).neg();
        }

        int256 underlyingWithdrawnExternal = balanceState.finalizeWithWithdraw(
            msg.sender, accountContext, !redeemToUnderlying
        );

        accountContext.setAccountContext(msg.sender);

        if (accountContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(msg.sender);
        }

        require(underlyingWithdrawnExternal <= 0);

        // No need to check supply caps
        return underlyingWithdrawnExternal.neg().toUint();
    }

    /// @notice Allows accounts to redeem nTokens into constituent assets and then absorb the assets
    /// into their portfolio. Due to the complexity here, it is not allowed to be called during a batch trading
    /// operation and must be done separately.
    /// @param redeemer the address that holds the nTokens to redeem
    /// @param currencyId the currency associated the nToken
    /// @param tokensToRedeem_ the amount of nTokens to convert to cash
    /// @param sellTokenAssets attempt to sell residual fCash and convert to cash
    /// @param acceptResidualAssets if true, will place any residual fCash that could not be sold (either due to slippage
    /// or because it was idiosyncratic) into the account's portfolio
    /// @dev auth:msg.sender auth:ERC1155
    /// @return total amount of asset cash redeemed
    /// @return true or false if there were residuals that were placed into the portfolio
    function nTokenRedeem(
        address redeemer,
        uint16 currencyId,
        uint96 tokensToRedeem_,
        bool sellTokenAssets,
        bool acceptResidualAssets
    ) external nonReentrant returns (int256, bool) {
        // ERC1155 can call this method during a post transfer event
        require(msg.sender == redeemer || msg.sender == address(this), "Unauthorized caller");
        int256 tokensToRedeem = int256(tokensToRedeem_);

        (AccountContext memory context, /* didSettle */) = _settleAccountIfRequired(redeemer);

        BalanceState memory balance;
        balance.loadBalanceState(redeemer, currencyId, context);

        require(balance.storedNTokenBalance >= tokensToRedeem, "Insufficient tokens");
        balance.netNTokenSupplyChange = tokensToRedeem.neg();

        (int256 totalPrimeCash, /* bool hasResidual */, PortfolioAsset[] memory assets) =
            nTokenRedeemAction.redeem(currencyId, tokensToRedeem, sellTokenAssets, acceptResidualAssets);

        // Set balances before transferring assets
        balance.netCashChange = totalPrimeCash;
        balance.finalizeNoWithdraw(redeemer, context);

        // The hasResidual flag is only set to true if selling residuals has failed, checking
        // if the length of assets is greater than zero will detect the presence of ifCash
        // assets that have not been sold.
        if (assets.length > 0) {
            // This method will store assets and update the account context in memory
            context = TransferAssets.placeAssetsInAccount(redeemer, context, assets);
        }

        context.setAccountContext(redeemer);
        if (context.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(redeemer);
        }

        // Do not check supply caps during nToken redemption, no deposits are taken during 
        // redemption so the supply should not change.

        return (totalPrimeCash, assets.length > 0);
    }

    /// @notice Settle the account if required, returning a reference to the account context. Also
    /// returns a boolean to indicate if it did settle.
    function _settleAccountIfRequired(address account)
        private
        returns (AccountContext memory, bool)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        if (accountContext.mustSettleAssets()) {
            return (SettleAssetsExternal.settleAccount(account, accountContext), true);
        } else {
            return (accountContext, false);
        }
    }

    /// @notice Get a list of deployed library addresses (sorted by library name)
    function getLibInfo() external pure returns (address, address, address, address) {
        return (
            address(FreeCollateralExternal),
            address(MigrateIncentives), 
            address(SettleAssetsExternal), 
            address(nTokenRedeemAction)
        );
    }
}
