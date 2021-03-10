// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/PerpetualToken.sol";
import "../common/AssetRate.sol";
import "../math/SafeInt256.sol";
import "../storage/StorageLayoutV1.sol";
import "../storage/BalanceHandler.sol";
import "interfaces/notional/PerpetualTokenActionInterface.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract PerpetualTokenAction is StorageLayoutV1, PerpetualTokenActionInterface {
    using BalanceHandler for BalanceState;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountStorage;
    using SafeInt256 for int;
    using SafeMath for uint;

    function perpetualTokenTotalSupply(
        address perpTokenAddress
    ) override external view returns (uint) {
        (
            /* currencyId */,
            uint totalSupply,
            /* incentiveRate */
        ) = PerpetualToken.getPerpetualTokenCurrencyIdAndSupply(
            perpTokenAddress
        );

        return totalSupply;
    }

    function perpetualTokenBalanceOf(
        uint16 currencyId,
        address account
    ) override external view returns (uint) {
        (
            /* int cashBalance */,
            int perpetualTokenBalance,
            /* uint lastIncentiveMint */
        ) = BalanceHandler.getBalanceStorage(account, currencyId);

        require(perpetualTokenBalance >= 0, "PA: negative balance");
        return uint(perpetualTokenBalance);
    }

    function perpetualTokenTransferAllowance(
        uint16 currencyId,
        address owner,
        address spender
    ) override external view returns (uint) {
        // This whitelist allowance supercedes any specific allowances
        uint allowance = perpTokenWhitelist[owner][spender];
        if (allowance > 0) return allowance;

        return perpTokenTransferAllowance[owner][spender][currencyId];
    }

    function perpetualTokenTransferApprove(
        uint16 currencyId,
        address owner,
        address spender,
        uint amount
    ) override external returns (bool) {
        address perpTokenAddress = PerpetualToken.getPerpetualTokenAddress(currencyId);
        require(msg.sender == perpTokenAddress, "PA: unauthorized caller");

        uint allowance = perpTokenTransferAllowance[owner][spender][currencyId];
        require(allowance == 0, "PA: allowance not zero");
        perpTokenTransferAllowance[owner][spender][currencyId] = amount;

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
    ) override external returns (bool) {
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
    ) override external returns (bool) {
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
    ) override external returns (bool) {
        uint allowance = perpTokenWhitelist[msg.sender][spender];
        require(allowance == 0, "PA: allowance not zero");
        perpTokenWhitelist[msg.sender][spender] = amount;

        return true;
    }

    function perpetualTokenPresentValueAssetDenominated(
        uint16 currencyId
    ) override external view returns (int) {
        (int totalAssetPV, /* portfolio */) = _getPerpetualTokenPV(currencyId);

        return totalAssetPV;
    }

    function perpetualTokenPresentValueUnderlyingDenominated(
        uint16 currencyId
    ) override external view returns (int) {
        (
            int totalAssetPV,
            PerpetualTokenPortfolio memory perpToken
        ) = _getPerpetualTokenPV(currencyId);

        return perpToken.cashGroup.assetRate.convertInternalToUnderlying(totalAssetPV);
    }

    function _getPerpetualTokenPV(
        uint currencyId
    ) private view returns (int, PerpetualTokenPortfolio memory) {
        uint blockTime = block.timestamp;
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolioView(currencyId);
        AccountStorage memory accountContext = AccountContextHandler.getAccountContext(perpToken.tokenAddress);

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
            /* uint totalSupply */,
            /* incentiveRate */
        ) = PerpetualToken.getPerpetualTokenCurrencyIdAndSupply(perpTokenAddress);

        AccountStorage memory senderContext = AccountContextHandler.getAccountContext(sender);
        BalanceState memory senderBalance = BalanceHandler.buildBalanceState(
            sender,
            currencyId,
            senderContext
        );

        AccountStorage memory recipientContext = AccountContextHandler.getAccountContext(recipient);
        BalanceState memory recipientBalance = BalanceHandler.buildBalanceState(
            recipient,
            currencyId,
            recipientContext
        );

        int amountInt = SafeCast.toInt256(amount);
        senderBalance.netPerpetualTokenTransfer = amountInt.neg();
        recipientBalance.netPerpetualTokenTransfer = amountInt;

        senderBalance.finalize(sender, senderContext, false);
        recipientBalance.finalize(recipient, recipientContext, false);
        // Finalize will update account contexts
        senderContext.setAccountContext(sender);
        recipientContext.setAccountContext(recipient);

        return true;
    }

}