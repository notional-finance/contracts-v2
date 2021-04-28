// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../global/Types.sol";
import "interfaces/notional/NotionalProxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface WETH9 {
    function withdraw(uint256 wad) external;

    function transfer(address dst, uint256 wad) external returns (bool);
}

interface IEscrow {
    function getBalances(address account) external view returns (int256[] memory);
}

interface UniswapPair {
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;
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
    UniswapPair public immutable wETHwBTCPair;
    WETH9 public immutable WETH;
    IERC20 public immutable WBTC;

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
        UniswapPair wETHwBTCPair_,
        WETH9 weth_,
        IERC20 wbtc_,
        uint16 v2Dai_,
        uint16 v2USDC_,
        uint16 v2WBTC_
    ) {
        Escrow = escrow_;
        NotionalV2 = notionalV2_;
        NotionalV1Erc1155 = erc1155_;
        wETHwBTCPair = wETHwBTCPair_;
        WETH = weth_;
        WBTC = wbtc_;
        V2_DAI = v2Dai_;
        V2_USDC = v2USDC_;
        V2_WBTC = v2WBTC_;
    }

    function enableWBTC() external {
        WBTC.approve(address(NotionalV2), type(uint256).max);
    }

    function migrateDaiEther(
        uint8 v2MarketIndex,
        uint88 v2fCashAmount,
        uint32 v2MaxBorrowImpliedRate,
        uint128 v1RepayAmount
    ) external {
        _flashBorrowCollateral(
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
        _flashBorrowCollateral(
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
        _flashBorrowCollateral(
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
        _flashBorrowCollateral(
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

    function _flashBorrowCollateral(
        uint16 v1DebtCurrencyId,
        uint16 v2DebtCurrencyId,
        uint16 v1CollateralId,
        uint16 v2CollateralId,
        bytes32 tradeData,
        uint128 v1RepayAmount
    ) internal returns (uint256) {
        int256[] memory balances = Escrow.getBalances(msg.sender);
        int256 collateralBalance =
            (v1CollateralId == V1_ETH ? balances[V1_ETH] : balances[V1_WBTC]);
        require(collateralBalance > 0);

        bytes memory encodedData =
            abi.encode(
                msg.sender,
                v1DebtCurrencyId,
                v2DebtCurrencyId,
                v1CollateralId,
                v2CollateralId,
                tradeData,
                v1RepayAmount,
                uint256(collateralBalance)
            );

        uint256 swapAmount = (uint256(collateralBalance) * 996) / 1000;
        if (v1CollateralId == V1_WBTC) {
            wETHwBTCPair.swap(swapAmount, 0, address(this), encodedData);
        } else if (v1CollateralId == V1_ETH) {
            wETHwBTCPair.swap(0, swapAmount, address(this), encodedData);
        }
    }

    function _repayFlashBorrow(uint256 v1CollateralId, uint256 amount) internal {
        bool success;
        if (v1CollateralId == V1_ETH) {
            success = WETH.transfer(msg.sender, amount);
        } else if (v1CollateralId == V1_WBTC) {
            success = WBTC.transfer(msg.sender, amount);
        }

        require(success);
    }

    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external {
        // Flash swap call must come from this contract
        require(sender == address(this), "sender mismatch");

        // decode message
        (
            address migrator,
            uint16 v1DebtCurrencyId,
            uint16 v2DebtCurrencyId,
            uint16 v1CollateralId,
            uint16 v2CollateralId,
            bytes32 tradeData,
            uint128 v1RepayAmount,
            uint256 collateralAmount
        ) = abi.decode(data, (address, uint16, uint16, uint16, uint16, bytes32, uint128, uint256));

        // transfer tokens to original caller
        uint256 swapAmount;
        if (v1CollateralId == V1_WBTC) {
            swapAmount = amount0;
        } else if (v1CollateralId == V1_ETH) {
            swapAmount = amount1;
            WETH.withdraw(amount1);
        }

        _migrate(
            migrator,
            v1DebtCurrencyId,
            v2DebtCurrencyId,
            v1CollateralId,
            v2CollateralId,
            tradeData,
            v1RepayAmount,
            collateralAmount,
            swapAmount
        );

        _repayFlashBorrow(v1CollateralId, collateralAmount);
    }

    function _migrate(
        address migrator,
        uint16 v1DebtCurrencyId,
        uint16 v2DebtCurrencyId,
        uint16 v1CollateralId,
        uint16 v2CollateralId,
        bytes32 tradeData,
        uint128 v1RepayAmount,
        uint256 collateralAmount,
        uint256 swapAmount
    ) internal {
        if (v2CollateralId == V2_ETH) {
            NotionalV2.depositUnderlyingToken{value: swapAmount}(
                migrator,
                v2CollateralId,
                swapAmount
            );
        } else {
            NotionalV2.depositUnderlyingToken(migrator, v2CollateralId, swapAmount);
        }

        BalanceActionWithTrades[] memory tradeExecution = new BalanceActionWithTrades[](1);
        {
            uint256 debtIndex = 0;
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
                migrator,
                tradeExecution
            );
        NotionalV2.safeTransferFrom(migrator, address(this), 0, 0, callData);

        {
            INotionalV1Erc1155.Deposit[] memory deposits = new INotionalV1Erc1155.Deposit[](1);
            INotionalV1Erc1155.Trade[] memory trades = new INotionalV1Erc1155.Trade[](0);
            INotionalV1Erc1155.Withdraw[] memory withdraws = new INotionalV1Erc1155.Withdraw[](1);

            // This will deposit what we borrowed in the `safeTransferFrom`
            deposits[0].currencyId = v1DebtCurrencyId;
            deposits[0].amount = v1RepayAmount;

            // This will withdraw to the current contract the collateral to repay the flash loan
            withdraws[0].currencyId = v1CollateralId;
            withdraws[0].to = address(this);
            withdraws[0].amount = uint128(collateralAmount);

            NotionalV1Erc1155.batchOperationWithdraw(
                migrator,
                uint32(block.timestamp),
                deposits,
                trades,
                withdraws
            );
        }
    }

    receive() external payable {}

    function onERC1155Received(
        address _operator,
        address _from,
        uint256 _id,
        uint256 _value,
        bytes calldata _data
    ) external returns (bytes4) {
        return 0xf23a6e61;
    }
}
