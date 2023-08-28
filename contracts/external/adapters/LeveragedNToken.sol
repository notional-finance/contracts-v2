// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../global/Types.sol";
import "../../../interfaces/notional/NotionalProxy.sol";
import "../../../interfaces/notional/NotionalCallback.sol";

contract LeveragedNTokenAdapter is NotionalCallback {
    struct EncodedData {
        uint16 currencyId;
        uint256 depositActionAmount;
    }

    string public constant name = "Leveraged NToken Adapter";
    NotionalProxy public immutable Notional;

    constructor(NotionalProxy notional) { Notional = notional; }

    /**
     * Batch Balance and Trade Action does not allow for margin deposit along with converting cash
     * balances to nTokens. Therefore, we use two authorized callback calls here to deposit margin,
     * borrow cash, and then convert some amount of cash to nTokens in a single transaction. These
     * methods use the `WithCallback` method that allows for Notional to perform ERC20 transfers
     * to take advantage of any existing token approvals.
     */
    function doLeveragedNToken(
        BalanceActionWithTrades[] calldata borrowAction,
        uint256 convertCashAmount
    ) external payable {
        require(borrowAction.length == 1); // dev: borrow action length
        require(borrowAction[0].actionType == DepositActionType.DepositUnderlying); // dev: deposit type
        bytes memory callbackData = abi.encode(borrowAction[0].currencyId, convertCashAmount);
        Notional.batchBalanceAndTradeActionWithCallback{value: msg.value}(
            msg.sender, borrowAction, callbackData
        );
    }

    function notionalCallback(
        address sender,
        address account,
        bytes calldata callbackData
    ) external override {
        require(msg.sender == address(Notional) && sender == address(this), "Unauthorized callback");
        // If callback data is empty then exit, this is the second callback to convert cash balances
        if (callbackData.length == 0) return;

        EncodedData memory data = abi.decode(callbackData, (EncodedData));
        BalanceActionWithTrades[] memory action = new BalanceActionWithTrades[](1);
        action[0].actionType = DepositActionType.ConvertCashToNToken;
        action[0].currencyId = data.currencyId;
        action[0].withdrawAmountInternalPrecision = 0;
        action[0].withdrawEntireCashBalance = false;
        // NOTE: this must always be set to true in v3
        action[0].redeemToUnderlying = true;

        if (data.depositActionAmount == 0) {
            (int256 cashBalance, /* */, /* */) = Notional.getAccountBalance(data.currencyId, account);
            require(cashBalance > 0);
            action[0].depositActionAmount = uint256(cashBalance);
        } else {
            action[0].depositActionAmount = data.depositActionAmount;
        }

        Notional.batchBalanceAndTradeActionWithCallback(account, action, "");
    }
}