// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../global/Types.sol";
import "interfaces/notional/NotionalProxy.sol";

interface IEscrow {
    function getBalances(address account) external view returns (int256[] memory);
}

interface INotionalV1Erc1155 {
    /** Notional V1 Types */
    struct Deposit {
        // Currency Id to deposit
        uint16 currencyId;
        // Amount of tokens to deposit
        uint128 amount;
    }

    /**
     * Used to describe withdraws in ERC1155.batchOperationWithdraw
     */
    struct Withdraw {
        // Destination of the address to withdraw to
        address to;
        // Currency Id to withdraw
        uint16 currencyId;
        // Amount of tokens to withdraw
        uint128 amount;
    }

    enum TradeType {TakeCurrentCash, TakefCash, AddLiquidity, RemoveLiquidity}

    /**
     * Used to describe a trade in ERC1155.batchOperation
     */
    struct Trade {
        TradeType tradeType;
        uint8 cashGroup;
        uint32 maturity;
        uint128 amount;
        bytes slippageData;
    }

    function batchOperationWithdraw(
        address account,
        uint32 maxTime,
        Deposit[] memory deposits,
        Trade[] memory trades,
        Withdraw[] memory withdraws
    ) external payable;
}

contract NotionalV1Migrator {
    IEscrow public immutable Escrow;
    NotionalProxy public immutable NotionalV2;
    INotionalV1Erc1155 public immutable NotionalV1Erc1155;
    uint16 internal constant V1_ETH = 0;
    uint16 internal constant V1_DAI = 1;
    uint16 internal constant V1_USDC = 2;
    uint16 internal constant V1_WBTC = 3;

    uint16 public constant V2_ETH = 1;
    uint16 public immutable V2_DAI;
    uint16 public immutable V2_USDC;
    uint16 public immutable V2_WBTC;

    constructor(
        IEscrow escrow_,
        NotionalProxy notionalV2_,
        INotionalV1Erc1155 erc1155_,
        uint16 v2Dai_,
        uint16 v2USDC_,
        uint16 v2WBTC_
    ) {
        Escrow = escrow_;
        NotionalV2 = notionalV2_;
        NotionalV1Erc1155 = erc1155_;
        V2_DAI = v2Dai_;
        V2_USDC = v2USDC_;
        V2_WBTC = v2WBTC_;
    }

    function migrateDaiEther(
        uint8 v2MarketIndex,
        uint88 v2fCashAmount,
        uint32 v2MaxBorrowImpliedRate,
        uint128 v1RepayAmount
    ) external {
        _migrate(
            V1_DAI,
            V2_DAI,
            V1_ETH,
            V2_ETH,
            _encodeTradeData(v2MarketIndex, v2fCashAmount, v2MaxBorrowImpliedRate),
            v1RepayAmount
        );
    }

    function migrateUSDCEther(
        uint8 v2MarketIndex,
        uint88 v2fCashAmount,
        uint32 v2MaxBorrowImpliedRate,
        uint128 v1RepayAmount
    ) external {
        _migrate(
            V1_USDC,
            V2_USDC,
            V1_ETH,
            V2_ETH,
            _encodeTradeData(v2MarketIndex, v2fCashAmount, v2MaxBorrowImpliedRate),
            v1RepayAmount
        );
    }

    function migrateDaiWBTC(
        uint8 v2MarketIndex,
        uint88 v2fCashAmount,
        uint32 v2MaxBorrowImpliedRate,
        uint128 v1RepayAmount
    ) external {
        _migrate(
            V1_DAI,
            V2_DAI,
            V1_WBTC,
            V2_WBTC,
            _encodeTradeData(v2MarketIndex, v2fCashAmount, v2MaxBorrowImpliedRate),
            v1RepayAmount
        );
    }

    function migrateUSDCWBTC(
        uint8 v2MarketIndex,
        uint88 v2fCashAmount,
        uint32 v2MaxBorrowImpliedRate,
        uint128 v1RepayAmount
    ) external {
        _migrate(
            V1_USDC,
            V2_USDC,
            V1_WBTC,
            V2_WBTC,
            _encodeTradeData(v2MarketIndex, v2fCashAmount, v2MaxBorrowImpliedRate),
            v1RepayAmount
        );
    }

    function _encodeTradeData(
        uint8 v2MarketIndex,
        uint88 v2fCashAmount,
        uint32 v2MaxBorrowImpliedRate
    ) private pure returns (bytes32) {
        return
            bytes32(
                (bytes32(uint256(TradeActionType.Borrow)) << 248) |
                    (bytes32(uint256(v2MarketIndex)) << 240) |
                    (bytes32(uint256(v2fCashAmount)) << 152) |
                    (bytes32(uint256(v2MaxBorrowImpliedRate)) << 120)
            );
    }

    function _flashBorrowCollateral(uint256 v1CollateralId) internal returns (uint256) {
        int256[] memory balances = Escrow.getBalances(msg.sender);
        // flash borrow
        // transfer to msg.sender
    }

    function _repayFlashBorrow(uint256 v1CollateralId, uint256 amount) internal {
        // transfer amount
    }

    function _migrate(
        uint16 v1DebtCurrencyId,
        uint16 v2DebtCurrencyId,
        uint16 v1CollateralId,
        uint16 v2CollateralId,
        bytes32 tradeData,
        uint128 v1RepayAmount
    ) internal {
        uint256 flashBorrowAmount = _flashBorrowCollateral(v1CollateralId);

        BalanceActionWithTrades[] memory tradeExecution = new BalanceActionWithTrades[](2);

        {
            uint256 collateralIndex = v2CollateralId < v2DebtCurrencyId ? 0 : 1;
            tradeExecution[collateralIndex].actionType = DepositActionType.DepositUnderlying;
            tradeExecution[collateralIndex].currencyId = v2CollateralId;
            // Denominated in underlying external precision
            tradeExecution[collateralIndex].depositActionAmount = flashBorrowAmount;
            // All other values are 0 or false
        }

        {
            uint256 debtIndex = v2CollateralId < v2DebtCurrencyId ? 1 : 0;
            tradeExecution[debtIndex].actionType = DepositActionType.None;
            tradeExecution[debtIndex].currencyId = v2DebtCurrencyId;
            tradeExecution[debtIndex].withdrawEntireCashBalance = true;
            tradeExecution[debtIndex].redeemToUnderlying = true;
            tradeExecution[debtIndex].trades = new bytes32[](1);
            tradeExecution[debtIndex].trades[0] = tradeData;
        }

        // This is going to borrow and withdraw the cash back into the msg.sender's wallet
        bytes memory callData =
            abi.encodeWithSelector(
                NotionalProxy.batchBalanceAndTradeAction.selector,
                msg.sender,
                tradeExecution
            );
        NotionalV2.safeTransferFrom(msg.sender, address(this), 0, 0, callData);

        {
            INotionalV1Erc1155.Deposit[] memory deposits = new INotionalV1Erc1155.Deposit[](1);
            INotionalV1Erc1155.Trade[] memory trades = new INotionalV1Erc1155.Trade[](0);
            INotionalV1Erc1155.Withdraw[] memory withdraws = new INotionalV1Erc1155.Withdraw[](1);

            // This will deposit what we borrowed in the `safeTransferFrom`
            deposits[0].currencyId = v1DebtCurrencyId;
            deposits[0].amount = v1RepayAmount;

            // This will withdraw to the current contract the collateral
            withdraws[0].currencyId = v1CollateralId;
            withdraws[0].to = address(this);
            withdraws[0].amount = uint128(flashBorrowAmount);

            NotionalV1Erc1155.batchOperationWithdraw(
                msg.sender,
                uint32(block.timestamp),
                deposits,
                trades,
                withdraws
            );
        }

        _repayFlashBorrow(v1CollateralId, flashBorrowAmount);
    }
}
