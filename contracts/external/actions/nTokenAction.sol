// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./ActionGuards.sol";
import "../../internal/nToken/nTokenHandler.sol";
import "../../internal/nToken/nTokenSupply.sol";
import "../../internal/nToken/nTokenCalculations.sol";
import "../../internal/markets/AssetRate.sol";
import "../../internal/balances/BalanceHandler.sol";
import "../../internal/balances/Incentives.sol";
import "../../math/SafeInt256.sol";
import "../../global/StorageLayoutV1.sol";
import "../../external/FreeCollateralExternal.sol";
import "../../../interfaces/notional/nTokenERC20.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract nTokenAction is StorageLayoutV1, nTokenERC20, ActionGuards {
    using BalanceHandler for BalanceState;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountContext;
    using nTokenHandler for nTokenPortfolio;
    using SafeInt256 for int256;
    using SafeMath for uint256;

    /// @notice Total number of tokens in circulation
    /// @param nTokenAddress The address of the nToken
    /// @return totalSupply number of tokens held
    function nTokenTotalSupply(address nTokenAddress)
        external
        view
        override
        returns (uint256 totalSupply)
    {
        // prettier-ignore
        (
            totalSupply,
            /* accumulatedNOTEPerNToken */,
            /* lastAccumulatedTime */
        ) = nTokenSupply.getStoredNTokenSupplyFactors(nTokenAddress);
    }

    /// @notice Get the number of tokens held by the `account`
    /// @param account The address of the account to get the balance of
    /// @return The number of tokens held
    function nTokenBalanceOf(uint16 currencyId, address account)
        external
        view
        override
        returns (uint256)
    {
        // prettier-ignore
        (
            /* int cashBalance */,
            int256 nTokenBalance,
            /* uint lastClaimTime */,
            /* uint accountIncentiveDebt */
        ) = BalanceHandler.getBalanceStorage(account, currencyId);

        require(nTokenBalance >= 0); // dev: negative nToken balance
        return uint256(nTokenBalance);
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
        emit Approval(msg.sender, spender, amount);
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
    function nTokenPresentValueAssetDenominated(uint16 currencyId)
        external
        view
        override
        returns (int256)
    {
        // prettier-ignore
        (
            int256 totalAssetPV,
            /* portfolio */
        ) = _getNTokenPV(currencyId);

        return totalAssetPV;
    }

    /// @notice Returns the present value of the nToken's assets denominated in underlying
    function nTokenPresentValueUnderlyingDenominated(uint16 currencyId)
        external
        view
        override
        returns (int256)
    {
        (int256 totalAssetPV, nTokenPortfolio memory nToken) = _getNTokenPV(currencyId);

        return nToken.cashGroup.assetRate.convertToUnderlying(totalAssetPV);
    }

    function _getNTokenPV(uint16 currencyId)
        private
        view
        returns (int256, nTokenPortfolio memory)
    {
        uint256 blockTime = block.timestamp;
        nTokenPortfolio memory nToken;
        nToken.loadNTokenPortfolioView(currencyId);

        int256 totalAssetPV = nTokenCalculations.getNTokenAssetPV(nToken, blockTime);

        return (totalAssetPV, nToken);
    }

    /// @notice Transferring tokens will also claim incentives at the same time
    function _transfer(
        uint16 currencyId,
        address sender,
        address recipient,
        uint256 amount
    ) internal returns (bool) {
        // This prevents amountInt from being negative
        int256 amountInt = SafeCast.toInt256(amount);

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
    function getLibInfo() external pure returns (address, address, address) {
        return (
            address(FreeCollateralExternal),
            address(MigrateIncentives),
            address(SettleAssetsExternal)
        );
    }
}
