// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/PerpetualToken.sol";
import "../common/AssetRate.sol";
import "../math/SafeInt256.sol";
import "../storage/SettleAssets.sol";
import "../storage/BalanceHandler.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract PerpetualTokenAction is SettleAssets {
    using BalanceHandler for BalanceState;
    using AssetRate for AssetRateParameters;
    using SafeInt256 for int;
    using SafeMath for uint;

    function perpetualTokenTotalSupply(address perpTokenAddress) external view returns (uint) {
        (/* currencyId */, uint totalSupply) = PerpetualToken.getPerpetualTokenCurrencyIdAndSupply(
            perpTokenAddress
        );

        return totalSupply;
    }

    function perpetualTokenBalanceOf(
        uint16 currencyId,
        address account
    ) external view returns (uint) {
        address perpTokenAddress = PerpetualToken.getPerpetualTokenAddress(currencyId);

        (
            /* int cashBalance */,
            int perpetualTokenBalance,
            /* int netCapitalDeposit */
        ) = BalanceHandler.getBalanceStorage(account, currencyId);

        require(perpetualTokenBalance >= 0, "PA: negative balance");
        return uint(perpetualTokenBalance);
    }

    function perpetualTokenTransferAllowance(
        uint16 currencyId,
        address owner,
        address spender
    ) external view returns (uint) {
        // This whitelist allowance supercedes any specific allowances
        uint allowance = perpTokenWhitelist[owner][spender];
        if (allowance > 0) return allowance;

        return perpTokenTransferAllowance[owner][spender][currencyId];
    }

    function perpetualTokenTransferApprove(
        uint16 currencyId,
        address spender,
        uint amount
    ) external returns (bool) {
        uint allowance = perpTokenTransferAllowance[msg.sender][spender][currencyId];
        require(allowance == 0, "PA: allowance not zero");
        perpTokenTransferAllowance[msg.sender][spender][currencyId] = amount;

        return true;
    }

    /**
     * @notice This method is called via the ERC20.transfer method and does not require authentication
     * via the allowance. Can only be called via the perp token address
     */
    function perpetualTokenTransfer(
        uint16 currencyId,
        address sender,
        address recipient,
        uint amount
    ) external returns (bool) {
        address perpTokenAddress = PerpetualToken.getPerpetualTokenAddress(currencyId);
        require(msg.sender == perpTokenAddress, "PA: unauthorized caller");

        return _transfer(perpTokenAddress, sender, recipient, amount);
    }

    /**
     * @notice This method can be called via the perp token or from the ERC20. This is authorized
     * via allowances.
     */
    function perpetualTokenTransferFrom(
        uint16 currencyId,
        address sender,
        address recipient,
        uint amount
    ) external returns (bool) {
        uint allowance = perpTokenWhitelist[sender][recipient];

        if (allowance > 0) {
            // This whitelist allowance supercedes any specific allowances
            require(allowance >= amount, "PA: insufficient allowance");
            perpTokenWhitelist[sender][recipient] = allowance.sub(amount);
        } else {
            // This is the specific allowance for the perp token.
            allowance = perpTokenTransferAllowance[sender][recipient][currencyId];
            require(allowance >= amount, "PA: insufficient allowance");
            perpTokenTransferAllowance[sender][recipient][currencyId] = allowance.sub(amount);
        }

        address perpTokenAddress = PerpetualToken.getPerpetualTokenAddress(currencyId);
        return _transfer(perpTokenAddress, sender, recipient, amount);
    }

    // Custom implementations
    /**
     * @notice This method will approve perpetual all perpetual token transfers to the specific sender. This
     * is used for simplifying UX, a user can approve all perpetual token transfers to an external exchange or
     * protocol in a single txn. This must be called directly on the proxy, not available via the ERC20 proxy.
     */
    function perpetualTokenTransferApproveAll(
        address spender,
        uint amount
    ) external returns (bool) {
        uint allowance = perpTokenWhitelist[msg.sender][spender];
        require(allowance == 0, "PA: allowance not zero");
        perpTokenWhitelist[msg.sender][spender] = amount;

        return true;
    }

    function perpetualTokenMint(
        uint16 currencyId,
        uint amountToDeposit,
        bool useCashBalance
    ) external returns (uint) {
        address perpTokenAddress = PerpetualToken.getPerpetualTokenAddress(currencyId);
        return _mintPerpetualToken(perpTokenAddress, msg.sender, amountToDeposit, useCashBalance);
    }

    function perpetualTokenMintFor(
        uint16 currencyId,
        address recipient,
        uint amountToDeposit,
        bool useCashBalance
    ) external returns (uint) {
        address perpTokenAddress = PerpetualToken.getPerpetualTokenAddress(currencyId);
        return _mintPerpetualToken(perpTokenAddress, recipient, amountToDeposit, useCashBalance);
    }

    function perpetualTokenRedeem(
        uint16 currencyId,
        uint tokensToRedeem
    ) external returns (bool) {
        revert("UNIMPLMENTED");
    }

    function perpetualTokenPresentValueAssetDenominated(
        uint16 currencyId
    ) external view returns (int) {
        address perpTokenAddress = PerpetualToken.getPerpetualTokenAddress(currencyId);
        (
            /* uint currencyId */,
            uint totalSupply
        ) = PerpetualToken.getPerpetualTokenCurrencyIdAndSupply(perpTokenAddress);

        (int totalAssetPV, /* portfolio */) = _getPerpetualTokenPV(currencyId);

        return totalAssetPV;
    }

    function perpetualTokenPresentValueUnderlyingDenominated(
        uint16 currencyId
    ) external view returns (int) {
        address perpTokenAddress = PerpetualToken.getPerpetualTokenAddress(currencyId);
        (
            /* uint currencyId */,
            uint totalSupply
        ) = PerpetualToken.getPerpetualTokenCurrencyIdAndSupply(perpTokenAddress);

        (
            int totalAssetPV,
            PerpetualTokenPortfolio memory perpToken
        ) = _getPerpetualTokenPV(currencyId);

        return perpToken.cashGroup.assetRate.convertInternalToUnderlying(totalAssetPV);
    }

    // TODO: move this into the PerpetualToken library?
    function _getPerpetualTokenPortfolio(
        uint currencyId
    ) private view returns (PerpetualTokenPortfolio memory, AccountStorage memory) {
        PerpetualTokenPortfolio memory perpToken;
        perpToken.tokenAddress = PerpetualToken.getPerpetualTokenAddress(currencyId);
        // TODO: this needs a getter and setter
        AccountStorage memory accountContext = accountContextMapping[perpToken.tokenAddress];

        perpToken.portfolioState = PortfolioHandler.buildPortfolioState(perpToken.tokenAddress, 0);
        (perpToken.cashGroup, perpToken.markets) = CashGroup.buildCashGroup(currencyId);

        return (perpToken, accountContext);
    }

    function _getPerpetualTokenPV(
        uint currencyId
    ) private view returns (int, PerpetualTokenPortfolio memory) {
        uint blockTime = block.timestamp;
        (
            PerpetualTokenPortfolio memory perpToken,
            AccountStorage memory accountContext
        ) = _getPerpetualTokenPortfolio(currencyId);

        (int totalAssetPV, /* bytes memory ifCashMapping */) = PerpetualToken.getPerpetualTokenPV(
            perpToken,
            accountContext,
            blockTime
        );

        return (totalAssetPV, perpToken);
    }

    function _transfer(
        address perpTokenAddress,
        address sender,
        address recipient,
        uint amount
    ) internal returns (bool) {
        (
            uint currencyId,
            uint totalSupply
        ) = PerpetualToken.getPerpetualTokenCurrencyIdAndSupply(perpTokenAddress);

        (
            int totalAssetPV,
            PerpetualTokenPortfolio memory perpToken
        ) = _getPerpetualTokenPV(currencyId);

        AccountStorage memory senderContext = accountContextMapping[sender];
        BalanceState memory senderBalance = BalanceHandler.buildBalanceState(
            sender,
            currencyId,
            senderContext.activeCurrencies
        );

        AccountStorage memory recipientContext = accountContextMapping[recipient];
        BalanceState memory recipientBalance = BalanceHandler.buildBalanceState(
            recipient,
            currencyId,
            recipientContext.activeCurrencies
        );

        int amountInt = SafeCast.toInt256(amount);
        senderBalance.netPerpetualTokenTransfer = amountInt.neg();
        senderBalance.netCapitalDeposit = totalAssetPV.mul(amountInt).div(int(totalSupply)).neg();

        recipientBalance.netPerpetualTokenTransfer = amountInt;
        recipientBalance.netCapitalDeposit = totalAssetPV.mul(amountInt).div(int(totalSupply));

        senderBalance.finalize(sender, senderContext);
        recipientBalance.finalize(recipient, recipientContext);
        // Finalize will update account contexts
        accountContextMapping[sender] = senderContext;
        accountContextMapping[recipient] = recipientContext;
    }

    function _mintPerpetualToken(
        address perpTokenAddress,
        address recipient,
        uint amountToDeposit_,
        bool useCashBalance
    ) internal returns (uint) {
        int amountToDeposit= SafeCast.toInt256(amountToDeposit_);
        uint blockTime = block.timestamp;

        // This needs to move to more generic
        (
            uint currencyId,
            uint totalSupply
        ) = PerpetualToken.getPerpetualTokenCurrencyIdAndSupply(perpTokenAddress);

        // First check if the account can support the deposit
        // TODO: this is quite a bit of boilerplate
        AccountStorage memory recipientContext = accountContextMapping[recipient];
        BalanceState memory recipientBalance = BalanceHandler.buildBalanceState(
            recipient,
            currencyId,
            recipientContext.activeCurrencies
        );

        // This needs to move to more generic
        (
            PerpetualTokenPortfolio memory perpToken,
            AccountStorage memory accountContext
        ) = _getPerpetualTokenPortfolio(currencyId);

        int tokensToMint = PerpetualToken.mintPerpetualToken(
            perpToken,
            accountContext,
            amountToDeposit,
            blockTime
        );

        if (useCashBalance && recipientBalance.storedCashBalance > 0) {
            if (recipientBalance.storedCashBalance > amountToDeposit) {
                recipientBalance.netCashChange = amountToDeposit.neg();
            } else {
                recipientBalance.netCashChange = recipientBalance.storedCashBalance.neg();
                recipientBalance.netCashTransfer = amountToDeposit.sub(recipientBalance.storedCashBalance);
            }
            
            // TODO: must free collateral check here
            if (recipientContext.hasDebt) {
                revert("UNIMPLMENTED");
            }
        } else {
            recipientBalance.netCashTransfer = amountToDeposit;
        }
        // TODO: should the balance context just hold the account address as well?
        recipientBalance.netPerpetualTokenTransfer = tokensToMint;
        recipientBalance.netCapitalDeposit = amountToDeposit;
        recipientBalance.finalize(recipient, recipientContext);
        accountContextMapping[recipient] = recipientContext;

        return SafeCast.toUint256(tokensToMint);
    }

}