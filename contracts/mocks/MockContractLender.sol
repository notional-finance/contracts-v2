// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../math/SafeInt256.sol";
import "../../interfaces/notional/NotionalProxy.sol";
import "../../interfaces/compound/CTokenInterface.sol";

contract MockContractLender {
    NotionalProxy immutable NOTIONAL;
    using SafeInt256 for int256;

    constructor(NotionalProxy _notional) {
        NOTIONAL = _notional;
    }

    function encodeLendTrade(
        uint256 marketIndex,
        uint256 fCashAmount,
        uint256 minImpliedRate
    ) internal pure returns (bytes32) {
        return
            bytes32(
                uint256(
                    (uint256(uint8(TradeActionType.Lend)) << 248) |
                        (marketIndex << 240) |
                        (fCashAmount << 152) |
                        (minImpliedRate << 120)
                )
            );
    }

    event Test(int256 cashAmount);

    function lend(uint16 currencyId, int88 cashAmount, uint8 marketIndex) external {
        (Token memory assetToken, Token memory underlyingToken) = NOTIONAL.getCurrency(currencyId);
        CTokenInterface(assetToken.tokenAddress).accrueInterest();

        int256 fCashAmount = NOTIONAL.getfCashAmountGivenCashAmount(
            currencyId,
            cashAmount, // this should be negative
            marketIndex,
            block.timestamp
        );

        IERC20(underlyingToken.tokenAddress).approve(address(NOTIONAL), type(uint256).max);
        BalanceActionWithTrades[] memory action = new BalanceActionWithTrades[](1);
        action[0].actionType = DepositActionType.DepositUnderlying;
        action[0].currencyId = currencyId;
        action[0].depositActionAmount = uint256(int256(cashAmount).abs() / 100 + 1);
        action[0].trades = new bytes32[](1);
        action[0].trades[0] = encodeLendTrade(marketIndex, uint88(uint256(fCashAmount)), 0);
        NOTIONAL.batchBalanceAndTradeAction(address(this), action);
    }
}
