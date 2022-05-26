// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

// WARNING: this is unaudited code. Use at your own risk. Very much recommended that this
// should be deployed behind an upgradeable proxy in case of issues.
// WARNING: Compound borrow will be credited to this contract and therefore this contract must hold your cTokens, not
// your wallet. This increases the risk of your collateral becoming locked or lost. PROCEED WITH CAUTION.

// Uses this release of OZ contracts: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.4-solc-0.7
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface WETH9 {
    function withdraw(uint256 wad) external;

    function transfer(address dst, uint256 wad) external returns (bool);
}

interface IEscrow {
    function getBalances(address account) external view returns (int256[] memory);

    function currencyIdToAddress(uint16 currencyId) external view returns (address);
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

    enum TradeType {
        TakeCurrentCash,
        TakefCash,
        AddLiquidity,
        RemoveLiquidity
    }

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

interface CEtherInterface {
    function mint() external payable;

    function borrow(uint256 borrowAmount) external returns (uint256);
}

interface CErc20Interface {
    function mint(uint256 mintAmount) external returns (uint256);

    function borrow(uint256 borrowAmount) external returns (uint256);
}

interface ComptrollerInterface {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
}

contract NotionalV1ToCompound {
    address public owner;
    IEscrow public immutable Escrow;
    INotionalV1Erc1155 public immutable NotionalV1Erc1155;
    UniswapPair public immutable wETHwBTCPair;
    WETH9 public immutable WETH;
    IERC20 public immutable WBTC;
    address public immutable Comptroller;
    address public immutable cETH;
    address public immutable cDAI;
    address public immutable cUSDC;
    address public immutable cWBTC;

    uint16 internal constant V1_ETH = 0;
    uint16 internal constant V1_DAI = 1;
    uint16 internal constant V1_USDC = 2;
    uint16 internal constant V1_WBTC = 3;

    function initialize() external {
        owner = msg.sender;
    }

    /// @dev Throws if called by any account other than the owner.
    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    /// @dev Transfers ownership of the contract to a new account (`newOwner`).
    /// Can only be called by the current owner.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        owner = newOwner;
    }

    constructor(
        IEscrow escrow_,
        INotionalV1Erc1155 erc1155_,
        UniswapPair wETHwBTCPair_,
        WETH9 weth_,
        IERC20 wbtc_,
        address comptroller_,
        address cETH_,
        address cDAI_,
        address cUSDC_,
        address cWBTC_
    ) {
        Escrow = escrow_;
        NotionalV1Erc1155 = erc1155_;
        Comptroller = comptroller_;
        wETHwBTCPair = wETHwBTCPair_;
        WETH = weth_;
        WBTC = wbtc_;
        cETH = cETH_;
        cDAI = cDAI_;
        cUSDC = cUSDC_;
        cWBTC = cWBTC_;
    }

    function migrateDaiEther(uint128 v1RepayAmount) external onlyOwner {
        _flashBorrowCollateral(V1_DAI, cDAI, V1_ETH, cETH, v1RepayAmount);
    }

    function migrateUSDCEther(uint128 v1RepayAmount) external onlyOwner {
        _flashBorrowCollateral(V1_USDC, cUSDC, V1_ETH, cETH, v1RepayAmount);
    }

    function migrateDaiWBTC(uint128 v1RepayAmount) external onlyOwner {
        _flashBorrowCollateral(V1_DAI, cDAI, V1_WBTC, cWBTC, v1RepayAmount);
    }

    function migrateUSDCWBTC(uint128 v1RepayAmount) external onlyOwner {
        _flashBorrowCollateral(V1_USDC, cUSDC, V1_WBTC, cWBTC, v1RepayAmount);
    }

    /** Use this to approve a spender for the cToken allowance */
    function approveAllowance(
        address token,
        address spender,
        uint256 allowance
    ) external onlyOwner {
        require(IERC20(token).approve(spender, allowance));
    }

    function _flashBorrowCollateral(
        uint16 v1DebtCurrencyId,
        address cTokenBorrowAddress,
        uint16 v1CollateralId,
        address cTokenCollateralAddress,
        uint128 v1RepayAmount
    ) internal returns (uint256) {
        int256[] memory balances = Escrow.getBalances(msg.sender);
        int256 collateralBalance = (
            v1CollateralId == V1_ETH ? balances[V1_ETH] : balances[V1_WBTC]
        );
        require(collateralBalance > 0);

        bytes memory encodedData = abi.encode(
            msg.sender,
            v1DebtCurrencyId,
            cTokenBorrowAddress,
            v1CollateralId,
            cTokenCollateralAddress,
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
            address cTokenBorrowAddress,
            uint16 v1CollateralId,
            address cTokenCollateral,
            uint128 v1RepayAmount,
            uint256 collateralAmount
        ) = abi.decode(data, (address, uint16, address, uint16, address, uint128, uint256));

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
            cTokenBorrowAddress,
            v1CollateralId,
            cTokenCollateral,
            v1RepayAmount,
            collateralAmount,
            swapAmount
        );

        _repayFlashBorrow(v1CollateralId, collateralAmount);
    }

    function _migrate(
        address migrator,
        uint16 v1DebtCurrencyId,
        address cTokenBorrowAddress,
        uint16 v1CollateralId,
        address cTokenCollateralAddress,
        uint128 v1RepayAmount,
        uint256 collateralAmount,
        uint256 swapAmount
    ) internal {
        // Mints cToken collateral from underlying that was flash borrowed
        if (cTokenCollateralAddress == address(cETH)) {
            CEtherInterface(cTokenCollateralAddress).mint{value: swapAmount}();
        } else {
            CErc20Interface(cTokenCollateralAddress).mint(swapAmount);
        }

        address[] memory markets = new address[](2);
        markets[0] = cTokenCollateralAddress;
        markets[1] = cTokenBorrowAddress;
        uint256[] memory returnCodes = ComptrollerInterface(Comptroller).enterMarkets(markets);
        require(returnCodes[0] == 0 && returnCodes[1] == 0, "Enter markets failed");

        // Borrows v1RepayAmount from Compound and will be sent to this contract's address
        // Debt will be credited to this contract address.
        CErc20Interface(cTokenBorrowAddress).borrow(v1RepayAmount);
        address debtCurrencyAddress = Escrow.currencyIdToAddress(v1DebtCurrencyId);
        // Transfer the borrowed assets to the migrator to repay the loan on Notional V1
        IERC20(debtCurrencyAddress).transfer(migrator, v1RepayAmount);

        {
            INotionalV1Erc1155.Deposit[] memory deposits = new INotionalV1Erc1155.Deposit[](1);
            INotionalV1Erc1155.Trade[] memory trades = new INotionalV1Erc1155.Trade[](0);
            INotionalV1Erc1155.Withdraw[] memory withdraws = new INotionalV1Erc1155.Withdraw[](1);

            // This will deposit what we borrowed from Compound
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
    ) external pure returns (bytes4) {
        return 0xf23a6e61;
    }
}
