// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./NotionalV2FlashLiquidatorBase.sol";
import "../../math/SafeInt256.sol";
import "../../../interfaces/IWstETH.sol";

contract NotionalV2FlashLiquidator is NotionalV2FlashLiquidatorBase {
    using SafeInt256 for int256;
    using SafeMath for uint256;

    constructor(
        NotionalProxy notionalV2_,
        address lendingPool_,
        address weth_,
        IWstETH wstETH_,
        address owner_,
        address dex1,
        address dex2
    )
        NotionalV2FlashLiquidatorBase(
            notionalV2_,
            lendingPool_,
            weth_,
            wstETH_,
            owner_,
            dex1,
            dex2
        )
    {}

    function _redeemAndWithdraw(
        uint16 nTokenCurrencyId,
        uint96 nTokenBalance,
        bool redeemToUnderlying
    ) internal override {
        BalanceAction[] memory action = new BalanceAction[](1);
        // If nTokenBalance is zero still try to withdraw entire cash balance
        action[0].actionType = nTokenBalance == 0
            ? DepositActionType.None
            : DepositActionType.RedeemNToken;
        action[0].currencyId = nTokenCurrencyId;
        action[0].depositActionAmount = nTokenBalance;
        action[0].withdrawEntireCashBalance = true;
        action[0].redeemToUnderlying = redeemToUnderlying;
        NotionalV2.batchBalanceAction(address(this), action);
    }

    function _sellfCashAssets(
        uint16 fCashCurrency,
        uint256[] memory fCashMaturities,
        int256[] memory fCashNotional,
        uint256 depositActionAmount,
        bool redeemToUnderlying
    ) internal override {
        uint256 blockTime = block.timestamp;
        BalanceActionWithTrades[] memory action = new BalanceActionWithTrades[](1);
        action[0].actionType = depositActionAmount > 0
            ? DepositActionType.DepositAsset
            : DepositActionType.None;
        action[0].depositActionAmount = depositActionAmount;
        action[0].currencyId = fCashCurrency;
        action[0].withdrawEntireCashBalance = true;
        action[0].redeemToUnderlying = redeemToUnderlying;

        uint256 numTrades;
        bytes32[] memory trades = new bytes32[](fCashMaturities.length);
        for (uint256 i; i < fCashNotional.length; i++) {
            if (fCashNotional[i] == 0) continue;
            (uint256 marketIndex, bool isIdiosyncratic) = DateTime.getMarketIndex(
                7,
                fCashMaturities[i],
                blockTime
            );
            // We don't trade it out here but if the contract does take on idiosyncratic cash we need to be careful
            if (isIdiosyncratic) continue;

            trades[numTrades] = bytes32(
                (uint256(fCashNotional[i] > 0 ? TradeActionType.Borrow : TradeActionType.Lend) <<
                    248) |
                    (marketIndex << 240) |
                    (uint256(uint88(fCashNotional[i].abs())) << 152)
            );
            numTrades++;
        }

        if (numTrades < trades.length) {
            // Shrink the trades array to length if it is not full
            bytes32[] memory newTrades = new bytes32[](numTrades);
            for (uint256 i; i < numTrades; i++) {
                newTrades[i] = trades[i];
            }
            action[0].trades = newTrades;
        } else {
            action[0].trades = trades;
        }

        NotionalV2.batchBalanceAndTradeAction(address(this), action);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "invalid new owner");
        owner = newOwner;
    }

    function wrapToWETH() external {
        _wrapToWETH();
    }

    function withdraw(address token, uint256 amount) external {
        IERC20(token).transfer(owner, amount);
    }

    receive() external payable {}
}
