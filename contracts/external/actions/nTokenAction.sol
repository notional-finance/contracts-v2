// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {StorageLayoutV1} from "../../global/StorageLayoutV1.sol";
import {Constants} from "../../global/Constants.sol";
import {nTokenHandler, nTokenPortfolio} from "../../internal/nToken/nTokenHandler.sol";
import {AccountContext, AccountContextHandler} from "../../internal/AccountContextHandler.sol";
import {nTokenSupply} from "../../internal/nToken/nTokenSupply.sol";
import {nTokenCalculations} from "../../internal/nToken/nTokenCalculations.sol";
import {AssetRate, AssetRateParameters} from "../../internal/markets/AssetRate.sol";
import {BalanceHandler, BalanceState} from "../../internal/balances/BalanceHandler.sol";
import {Token, TokenType, TokenHandler} from "../../internal/balances/TokenHandler.sol";
import {Incentives} from "../../internal/balances/Incentives.sol";

import {ActionGuards} from "./ActionGuards.sol";
import {nTokenRedeemAction} from "./nTokenRedeemAction.sol";
import {nTokenMintAction} from "./nTokenMintAction.sol";
import {FreeCollateralExternal} from "../FreeCollateralExternal.sol";
import {SettleAssetsExternal} from "../SettleAssetsExternal.sol";
import {MigrateIncentives} from "../MigrateIncentives.sol";
import {INTokenAction} from "../../../interfaces/notional/INTokenAction.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

contract nTokenAction is StorageLayoutV1, INTokenAction, ActionGuards {
    using BalanceHandler for BalanceState;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountContext;
    using nTokenHandler for nTokenPortfolio;
    using TokenHandler for Token;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;

    /// @notice Total number of tokens in circulation
    /// @param nTokenAddress The address of the nToken
    /// @return totalSupply number of tokens held
    function nTokenTotalSupply(address nTokenAddress) external view override returns (uint256 totalSupply) {
        (totalSupply, /* */, /* */) = nTokenSupply.getStoredNTokenSupplyFactors(nTokenAddress);
    }

    /// @notice Get the number of tokens held by the `account`
    /// @param account The address of the account to get the balance of
    /// @return The number of tokens held
    function nTokenBalanceOf(uint16 currencyId, address account) external view override returns (uint256) {
        ( /* */, int256 nTokenBalance, /* */, /*  */) = BalanceHandler.getBalanceStorage(account, currencyId);
        return nTokenBalance.toUint();
    }

    /// @notice Get the number of tokens `spender` is approved to spend on behalf of `account`
    /// @param currencyId Currency id of the nToken account
    /// @param tokenHolder The address of the account holding the funds
    /// @param spender The address of the account spending the funds
    /// @return The number of tokens approved
    function nTokenTransferAllowance(
        uint16 currencyId,
        address tokenHolder,
        address spender
    ) external view override returns (uint256) {
        // The specific allowance overrides the blanket whitelist
        uint256 allowance = nTokenAllowance[tokenHolder][spender][currencyId];
        if (allowance > 0) {
            return allowance;
        } else {
            return nTokenWhitelist[tokenHolder][spender];
        }
    }

    /// @notice Approve `spender` to transfer up to `amount` from `src`
    /// @dev auth:nTokenProxy
    /// @param currencyId Currency id of the nToken account
    /// @param tokenHolder The address of the account holding the funds
    /// @param spender The address of the account which may transfer tokens
    /// @param amount The number of tokens that are approved (2^256-1 means infinite)
    /// @return Whether or not the approval succeeded
    function nTokenTransferApprove(
        uint16 currencyId,
        address tokenHolder,
        address spender,
        uint256 amount
    ) external override returns (bool) {
        address nTokenAddress = nTokenHandler.nTokenAddress(currencyId);
        require(msg.sender == nTokenAddress, "Unauthorized caller");
        require(tokenHolder != address(0));

        nTokenAllowance[tokenHolder][spender][currencyId] = amount;

        return true;
    }

    /// @notice Transfer `amount` tokens from `msg.sender` to `dst`
    /// @dev auth:nTokenProxy
    /// @param from The address of the destination account
    /// @param to The address of the destination account
    /// @param amount The number of tokens to transfer
    /// @return Whether or not the transfer succeeded
    function nTokenTransfer(
        uint16 currencyId,
        address from,
        address to,
        uint256 amount
    ) external override returns (bool) {
        address nTokenAddress = nTokenHandler.nTokenAddress(currencyId);
        require(msg.sender == nTokenAddress, "Unauthorized caller");
        require(from != to, "Cannot transfer to self");
        requireValidAccount(to);

        return _transfer(currencyId, from, to, amount);
    }

    /// @notice Transfer `amount` tokens from `src` to `dst`
    /// @dev auth:nTokenProxy
    /// @param currencyId Currency id of the nToken
    /// @param spender The address of the original caller
    /// @param from The address of the source account
    /// @param to The address of the destination account
    /// @param amount The number of tokens to transfer
    /// @return Whether or not the transfer succeeded
    function nTokenTransferFrom(
        uint16 currencyId,
        address spender,
        address from,
        address to,
        uint256 amount
    ) external override returns (bool) {
        address nTokenAddress = nTokenHandler.nTokenAddress(currencyId);
        require(msg.sender == nTokenAddress, "Unauthorized caller");
        require(from != to, "Cannot transfer to self");
        requireValidAccount(to);

        uint256 allowance = nTokenAllowance[from][spender][currencyId];

        if (allowance > 0) {
            // This is the specific allowance for the nToken.
            require(allowance >= amount, "Insufficient allowance");
            // Overflow checked above
            nTokenAllowance[from][spender][currencyId] = allowance - amount;
        } else {
            // This whitelist allowance works across all nTokens
            allowance = nTokenWhitelist[from][spender];
            require(allowance >= amount, "Insufficient allowance");
            // Overflow checked above
            nTokenWhitelist[from][spender] = allowance - amount;
        }

        return _transfer(currencyId, from, to, amount);
    }

    /// @notice Will approve all nToken transfers to the specific sender. This is used for simplifying UX, a user can approve
    /// all token transfers to an external exchange or protocol in a single txn. This must be called directly
    /// on the Notional contract, not available via the ERC20 proxy.
    /// @dev emit:Approval
    /// @dev auth:msg.sender
    /// @param spender The address of the account which may transfer tokens
    /// @param amount The number of tokens that are approved
    /// @return Whether or not the approval succeeded
    function nTokenTransferApproveAll(address spender, uint256 amount)
        external
        override
        returns (bool)
    {
        nTokenWhitelist[msg.sender][spender] = amount;
        emit nTokenApproveAll(msg.sender, spender, amount);
        return true;
    }

    /// @notice Claims incentives accrued on all nToken balances and transfers them to the msg.sender
    /// @dev auth:msg.sender
    /// @return Total amount of incentives claimed
    function nTokenClaimIncentives() external override returns (uint256) {
        address account = msg.sender;
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        uint256 totalIncentivesClaimed = 0;
        BalanceState memory balanceState;

        if (accountContext.isBitmapEnabled()) {
            balanceState.loadBalanceState(account, accountContext.bitmapCurrencyId, accountContext);
            if (balanceState.storedNTokenBalance > 0) {
                // balance state is updated inside claim incentives manual
                totalIncentivesClaimed = balanceState.claimIncentivesManual(account);
            }
        }

        bytes18 currencies = accountContext.activeCurrencies;
        while (currencies != 0) {
            uint16 currencyId = uint16(bytes2(currencies) & Constants.UNMASK_FLAGS);

            balanceState.loadBalanceState(account, currencyId, accountContext);
            if (balanceState.storedNTokenBalance > 0) {
                // balance state is updated inside claim incentives manual
                totalIncentivesClaimed = totalIncentivesClaimed
                    .add(balanceState.claimIncentivesManual(account));
            }

            currencies = currencies << 16;
        }

        // NOTE: no need to set account context after claiming incentives. No currencies
        // or fCash assets have been added or changed.
        return totalIncentivesClaimed;
    }

    /// @notice Returns the present value of the nToken's assets denominated in asset tokens
    function nTokenPresentValueAssetDenominated(uint16 currencyId) external view override returns (
        int256 totalAssetPV
    ) {
        (totalAssetPV, /* portfolio */) = _getNTokenPV(currencyId);
    }

    /// @notice Returns the present value of the nToken's assets denominated in underlying
    function nTokenPresentValueUnderlyingDenominated(uint16 currencyId) external view override returns (
        int256 totalUnderlyingPVInternal
    ) {
        (int256 totalAssetPV, nTokenPortfolio memory nToken) = _getNTokenPV(currencyId);
        totalUnderlyingPVInternal = nToken.cashGroup.assetRate.convertToUnderlying(totalAssetPV);
    }

    /// @notice Returns the present value of the nToken's assets denominated in the underlying's native
    /// token precision
    function nTokenPresentValueUnderlyingExternal(uint16 currencyId) external view override returns (
        uint256 underlyingExternal
    ) {
        (int256 totalAssetPV, nTokenPortfolio memory nToken) = _getNTokenPV(currencyId);
        AssetRateParameters memory assetRate = nToken.cashGroup.assetRate;
        underlyingExternal = SafeInt256.toUint(
            assetRate.convertToUnderlying(totalAssetPV)
                .mul(assetRate.underlyingDecimals)
                .div(Constants.INTERNAL_TOKEN_PRECISION)
        );
    }

    function _getNTokenPV(uint16 currencyId) private view returns (
        int256 totalAssetPV, nTokenPortfolio memory nToken
    ) {
        nToken.loadNTokenPortfolioView(currencyId);
        totalAssetPV = nTokenCalculations.getNTokenAssetPV(nToken, block.timestamp);
    }

    /// @notice Redeems nTokens via the ERC4626 proxy which means that the shares (nTokens to redeem)
    /// are always redeemed to underlying (reverting on residuals) and transferred back to the owner.
    /// Due to how BalanceState.finalize is structured, we do not handle cases where receiver != owner.
    function nTokenRedeemViaProxy(uint16 currencyId, uint256 shares, address receiver, address owner)
        external override returns (uint256) 
    {
        address nTokenAddress = nTokenHandler.nTokenAddress(currencyId);
        // We don't implement separate receivers for ERC4626
        require(msg.sender == nTokenAddress && receiver == owner, "Unauthorized caller");
        int256 tokensToRedeem = shares.toInt();
        BalanceState memory balanceState;
        AccountContext memory ownerContext = AccountContextHandler.getAccountContext(owner);
        // If the owner has debt we will have to do a FC check, so here we settle assets first.
        if (ownerContext.mustSettleAssets()) {
            ownerContext = SettleAssetsExternal.settleAccount(owner, ownerContext);
        }

        balanceState.loadBalanceState(owner, currencyId, ownerContext);
        balanceState.netNTokenSupplyChange = balanceState.netNTokenSupplyChange.sub(tokensToRedeem);
        int256 assetCash = nTokenRedeemAction.nTokenRedeemViaBatch(currencyId, tokensToRedeem);
        // All of the tokens redeemed will be transferred back to the owner and redeemed to underlying
        balanceState.netCashChange = assetCash;
        balanceState.netAssetTransferInternalPrecision = assetCash.neg();
        balanceState.finalize({account: owner, accountContext: ownerContext, redeemToUnderlying: true});
        ownerContext.setAccountContext(owner);

        // If the owner has debts, we must nee a free collateral check here
        if (ownerContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(owner);
        }

        // Calling proxy will emit the proper transfer event
        return assetCash.toUint();
    }

    /// @notice Mints nTokens via the ERC4626 proxy which means that the proxy will have transferred underlying
    /// tokens to Notional before this method is called.
    function nTokenMintViaProxy(uint16 currencyId, uint256 assets, address receiver)
        external payable override returns (uint256) {
        address nTokenAddress = nTokenHandler.nTokenAddress(currencyId);
        require(msg.sender == nTokenAddress, "Unauthorized caller");

        // If we are minting nETH then we assets must equal the ETH sent
        if (currencyId == Constants.ETH_CURRENCY_ID) require(assets == msg.value);

        // At this point the proxy will have transferred underlying so we convert it to asset tokens.
        Token memory assetToken = TokenHandler.getAssetToken(currencyId);
        int256 assetTokensReceivedInternal;
        if (assetToken.tokenType == TokenType.NonMintable) {
            // NonMintable asset tokens are just converted to internal precision
            assetTokensReceivedInternal = assetToken.convertToInternal(assets.toInt());
        } else {
            assetTokensReceivedInternal = assetToken.convertToInternal(
                assetToken.mint({currencyId: currencyId, underlyingAmountExternal: assets})
            );
        }

        BalanceState memory balanceState;
        AccountContext memory receiverContext = AccountContextHandler.getAccountContext(receiver);
        balanceState.loadBalanceState(receiver, currencyId, receiverContext);

        int256 nTokensMinted = nTokenMintAction.nTokenMint(currencyId, assetTokensReceivedInternal);
        balanceState.netNTokenSupplyChange = nTokensMinted;
        balanceState.finalize(receiver, receiverContext, true);
        receiverContext.setAccountContext(receiver);

        // No need for a free collateral check, we are depositing into the account and their collateral
        // position will necessarily increase.
        return nTokensMinted.toUint();
    }

    /// @notice Transferring tokens will also claim incentives at the same time
    function _transfer(
        uint16 currencyId,
        address sender,
        address recipient,
        uint256 amount
    ) internal returns (bool) {
        // This prevents amountInt from being negative
        int256 amountInt = SafeInt256.toInt(amount);

        AccountContext memory senderContext = AccountContextHandler.getAccountContext(sender);
        // If sender has debt then we will check free collateral which will revert if we have not
        // settled assets first. To prevent this we settle sender context if required.
        if (senderContext.mustSettleAssets()) {
            senderContext = SettleAssetsExternal.settleAccount(sender, senderContext);
        }

        BalanceState memory senderBalance;
        senderBalance.loadBalanceState(sender, currencyId, senderContext);
        senderBalance.netNTokenTransfer = amountInt.neg();
        senderBalance.finalize(sender, senderContext, false);
        senderContext.setAccountContext(sender);

        AccountContext memory recipientContext = AccountContextHandler.getAccountContext(recipient);
        BalanceState memory recipientBalance;
        recipientBalance.loadBalanceState(recipient, currencyId, recipientContext);
        recipientBalance.netNTokenTransfer = amountInt;
        recipientBalance.finalize(recipient, recipientContext, false);
        recipientContext.setAccountContext(recipient);

        // nTokens are used as collateral so we have to check the free collateral when we transfer. Only the
        // sender needs a free collateral check, the receiver's net free collateral position will only increase
        if (senderContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(sender);
        }

        return true;
    }

    /// @notice Get a list of deployed library addresses (sorted by library name)
    function getLibInfo() external pure returns (address, address, address, address, address) {
        return (
            address(FreeCollateralExternal),
            address(MigrateIncentives),
            address(SettleAssetsExternal),
            address(nTokenMintAction),
            address(nTokenRedeemAction)
        );
    }
}
