// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../../global/Types.sol";
import "../../../interfaces/notional/NotionalProxy.sol";
import "../../../interfaces/notional/NotionalCallback.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface WETH9 {
    function withdraw(uint256 wad) external;

    function transfer(address dst, uint256 wad) external returns (bool);
}

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

contract NotionalV1ToNotionalV2 is NotionalCallback {
    string public name = "Notional V1 to Notional V2";
    IEscrow public immutable Escrow;
    NotionalProxy public immutable NotionalV2;
    INotionalV1Erc1155 public immutable NotionalV1Erc1155;
    WETH9 public immutable WETH;
    IERC20 public immutable WBTC;

    uint16 internal constant V1_ETH = 0;
    uint16 internal constant V1_DAI = 1;
    uint16 internal constant V1_USDC = 2;
    uint16 internal constant V1_WBTC = 3;

    uint16 public constant V2_ETH = 1;
    uint16 public constant V2_DAI = 2;
    uint16 public constant V2_USDC = 3;
    uint16 public constant V2_WBTC = 4;

    constructor(
        IEscrow escrow_,
        NotionalProxy notionalV2_,
        INotionalV1Erc1155 erc1155_,
        WETH9 weth_,
        IERC20 wbtc_
    ) {
        Escrow = escrow_;
        NotionalV2 = notionalV2_;
        NotionalV1Erc1155 = erc1155_;
        WETH = weth_;
        WBTC = wbtc_;
        wbtc_.approve(address(notionalV2_), type(uint256).max);
    }

    function migrateDaiEther(
        uint128 v1RepayAmount,
        BalanceActionWithTrades[] calldata borrowAction
    ) external {
        // borrow on notional via special flash loan facility
        //  - borrow repayment amount
        //  - withdraw to wallet
        // receive callback (tokens transferred to borrowing account)
        //   -> inside callback
        //   -> repay Notional V1
        //   -> deposit collateral to notional v2 (account needs to have set approvals)
        //   -> exit callback
        // inside original borrow, check FC
        bytes memory encodedData = abi.encode(V1_DAI, v1RepayAmount, V1_ETH, V2_ETH);
        NotionalV2.batchBalanceAndTradeActionWithCallback(msg.sender, borrowAction, encodedData);
    }

    function migrateUSDCEther(
        uint128 v1RepayAmount,
        BalanceActionWithTrades[] calldata borrowAction
    ) external {
        bytes memory encodedData = abi.encode(V1_USDC, v1RepayAmount, V1_ETH, V2_ETH);
        NotionalV2.batchBalanceAndTradeActionWithCallback(msg.sender, borrowAction, encodedData);
    }

    function migrateDaiWBTC(
        uint128 v1RepayAmount,
        BalanceActionWithTrades[] calldata borrowAction
    ) external {
        bytes memory encodedData = abi.encode(V1_DAI, v1RepayAmount, V1_WBTC, V2_WBTC);
        NotionalV2.batchBalanceAndTradeActionWithCallback(msg.sender, borrowAction, encodedData);
    }

    function migrateUSDCWBTC(
        uint128 v1RepayAmount,
        BalanceActionWithTrades[] calldata borrowAction
    ) external {
        bytes memory encodedData = abi.encode(V1_USDC, v1RepayAmount, V1_WBTC, V2_WBTC);
        NotionalV2.batchBalanceAndTradeActionWithCallback(msg.sender, borrowAction, encodedData);
    }

    function notionalCallback(
        address sender,
        address account,
        bytes calldata callbackData
    ) external override {
        require(msg.sender == address(NotionalV2) && sender == address(this), "Unauthorized callback");
        (
            uint16 v1DebtCurrencyId,
            uint128 v1RepayAmount,
            uint16 v1CollateralId,
            uint16 v2CollateralId
        ) = abi.decode(callbackData, (uint16, uint128, uint16, uint16));

        int256[] memory balances = Escrow.getBalances(account);
        // Notional V1 returns an array of balances for all listed currencies. We do not allow
        // collateral to be USDC or DAI during migration.
        int256 collateralBalance =
            (v1CollateralId == V1_ETH ? balances[V1_ETH] : balances[V1_WBTC]);
        require(0 < collateralBalance && collateralBalance <= type(uint128).max);

        {
            INotionalV1Erc1155.Deposit[] memory deposits = new INotionalV1Erc1155.Deposit[](1);
            INotionalV1Erc1155.Trade[] memory trades = new INotionalV1Erc1155.Trade[](0);
            INotionalV1Erc1155.Withdraw[] memory withdraws = new INotionalV1Erc1155.Withdraw[](1);

            // This will deposit what was borrowed from the account's wallet
            deposits[0] = INotionalV1Erc1155.Deposit(v1DebtCurrencyId, v1RepayAmount);

            // This will withdraw to the current contract the collateral to repay the flash loan,
            // overflow checked above
            withdraws[0] = INotionalV1Erc1155.Withdraw(
                address(this), // Will withdraw collateral to this contract, to be deposited below
                v1CollateralId,
                uint128(collateralBalance)
            );

            NotionalV1Erc1155.batchOperationWithdraw(
                account,
                uint32(block.timestamp),
                deposits,
                trades,
                withdraws
            );
        }

        // Overflow checked above, cannot be negative
        uint256 v2CollateralBalance = uint256(collateralBalance);
        if (v2CollateralId == V2_ETH) {
            // Notional V1 uses WETH, but V2 uses ETH
            WETH.withdraw(v2CollateralBalance);
            NotionalV2.depositUnderlyingToken{value: v2CollateralBalance}(
                account,
                v2CollateralId,
                v2CollateralBalance
            );
        } else {
            NotionalV2.depositUnderlyingToken(account, v2CollateralId, v2CollateralBalance);
        }

        // When this exits it will do a free collateral check
    }

    receive() external payable {
        // Allows contract to receive ETH during WETH withdraw
    }
}
