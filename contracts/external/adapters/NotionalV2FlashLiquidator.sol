// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/markets/DateTime.sol";
import "../../math/SafeInt256.sol";
import "interfaces/notional/NotionalProxy.sol";
import "interfaces/compound/CTokenInterface.sol";
import "interfaces/compound/CErc20Interface.sol";
import "interfaces/compound/CEtherInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

interface IFlashLoanReceiver {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);

    //   function ADDRESSES_PROVIDER() external view returns (address);

    //   function LENDING_POOL() external view returns (address);
}

interface WETH9 {
    function deposit() external payable;

    function withdraw(uint256 wad) external;

    function transfer(address dst, uint256 wad) external returns (bool);
}

abstract contract NotionalV2FlashLiquidator is IFlashLoanReceiver {
    using SafeInt256 for int256;
    using SafeMath for uint256;

    enum LiquidationAction {
        LocalCurrency_NoTransferFee,
        CollateralCurrency_NoTransferFee,
        LocalfCash_NoTransferFee,
        CrossCurrencyfCash_NoTransferFee,
        LocalCurrency_WithTransferFee,
        CollateralCurrency_WithTransferFee,
        LocalfCash_WithTransferFee,
        CrossCurrencyfCash_WithTransferFee
    }

    NotionalProxy public immutable NotionalV2;
    mapping(address => address) underlyingToCToken;
    address public immutable WETH;
    address public immutable cETH;
    address public immutable OWNER;
    address public immutable LENDING_POOL;
    address public immutable ADDRESS_PROVIDER;

    modifier onlyOwner() {
        require(msg.sender == OWNER);
        _;
    }

    constructor(
        NotionalProxy notionalV2_,
        address lendingPool_,
        address addressProvider_,
        address weth_,
        address cETH_
    ) {
        OWNER = msg.sender;
        NotionalV2 = notionalV2_;
        LENDING_POOL = lendingPool_;
        ADDRESS_PROVIDER = addressProvider_;
        WETH = weth_;
        cETH = cETH_;
    }

    function setCTokenAddress(address cToken) external onlyOwner {
        address underlying = CTokenInterface(cToken).underlying();
        // Notional V2 needs to be able to pull cTokens
        checkAllowanceOrSet(cToken, address(NotionalV2));
        // Lending pool needs to be able to pull underlying
        checkAllowanceOrSet(underlying, LENDING_POOL);
        underlyingToCToken[underlying] = cToken;
    }

    function approveToken(address token, address spender) external onlyOwner {
        IERC20(token).approve(spender, type(uint256).max);
    }

    event OperationExecuted(uint256 cdai, uint256 dai, uint256 ceth, uint256 weth, uint256 eth);

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(initiator == OWNER); // dev: unauthorized caller
        require(msg.sender == LENDING_POOL); // dev: unauthorized caller
        LiquidationAction action = LiquidationAction(abi.decode(params, (uint8)));

        // Mint cTokens for incoming assets, if required. If there are transfer fees
        // the we deposit underlying instead inside each _liquidate call instead
        if (!_hasTransferFees(action)) _mintCTokens(assets, amounts);

        address from;
        if (
            action == LiquidationAction.LocalCurrency_WithTransferFee ||
            action == LiquidationAction.LocalCurrency_NoTransferFee
        ) {
            _liquidateLocal(action, params, assets);
        } else if (
            action == LiquidationAction.CollateralCurrency_WithTransferFee ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee
        ) {
           from =  _liquidateCollateral(action, params, assets);
        } else if (
            action == LiquidationAction.LocalfCash_WithTransferFee ||
            action == LiquidationAction.LocalfCash_NoTransferFee
        ) {
            _liquidateLocalfCash(action, params, assets);
        } else if (
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee ||
            action == LiquidationAction.CrossCurrencyfCash_NoTransferFee
        ) {
            _liquidateCrossCurrencyfCash(action, params, assets);
        }

        _redeemCTokens(assets);

        emit OperationExecuted(
            IERC20(underlyingToCToken[assets[0]]).balanceOf(address(this)),
            IERC20(assets[0]).balanceOf(address(this)),
            IERC20(cETH).balanceOf(address(this)),
            IERC20(WETH).balanceOf(address(this)),
            address(this).balance
        );

        if (
            action == LiquidationAction.CollateralCurrency_WithTransferFee ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee ||
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee ||
            action == LiquidationAction.CrossCurrencyfCash_NoTransferFee
        ) {
            _executeDexTrade(action, from, assets[0], amounts[0], premiums[0], params);
        }

        revert();

        // The lending pool should have enough approval to pull the required amount from the contract
        return true;
    }

    function executeDexTrade(
        address from,
        address to,
        uint256 amountOut,
        bytes memory params
    ) internal virtual;

    function _executeDexTrade(
        LiquidationAction action,
        address from,
        address to,
        uint256 amount,
        uint256 premium,
        bytes calldata params
    ) internal {
        uint256 bal = IERC20(from).balanceOf(address(this));
        uint256 total = amount + premium;

        if (bal >= total) {
            return;
        }

        uint256 collateralCurrency;
        bytes memory tradeCallData;

        if (
            action == LiquidationAction.CollateralCurrency_WithTransferFee ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee
        ) {
            // prettier-ignore
            (
                /* uint8 action */,
                /* address liquidateAccount */,
                /* uint256 localCurrency */,
                /* collateralCurrency */,
                /* uint128 maxCollateralLiquidation */,
                /* uint96 maxNTokenLiquidation */,
                tradeCallData
            ) = abi.decode(params, (uint8, address, uint256, uint256, uint128, uint96, bytes));
        } else {
            // prettier-ignore
            (
                /* uint8 action */,
                /* address liquidateAccount */,
                /* uint256 localCurrency*/,
                /* collateralCurrency */,
                /* fCashMaturities */,
                /* maxfCashLiquidateAmounts */,
                tradeCallData
            ) = abi.decode(params, (uint8, address, uint256, uint256, uint256[], uint256[], bytes));
        }

        emit OperationExecuted(
            IERC20(from).balanceOf(address(this)),
            IERC20(to).balanceOf(address(this)),
            IERC20(cETH).balanceOf(address(this)),
            IERC20(WETH).balanceOf(address(this)),
            address(this).balance
        );
        
        executeDexTrade(from, to, total - bal, tradeCallData);

        // Arbitrary call to any DEX to trade back to local currency
        /*(bool success, bytes memory retVal) = tradeContract.call{value: tradeETHValue}(
            tradeCallData
        );
        require(success, _getRevertMsg(retVal)); */
    }

    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (_returnData.length < 68) return "Transaction reverted silently";

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string)); // All that remains is the revert string
    }

    function _mintCTokens(address[] calldata assets, uint256[] calldata amounts) internal {
        for (uint256 i; i < assets.length; i++) {
            if (assets[i] == WETH) {
                // Withdraw WETH to ETH and mint CEth
                WETH9(WETH).withdraw(amounts[i]);
                CEtherInterface(cETH).mint{value: amounts[i]}();
            } else {
                address cToken = underlyingToCToken[assets[i]];
                if (cToken != address(0)) {
                    checkAllowanceOrSet(assets[i], cToken);
                    CErc20Interface(cToken).mint(amounts[i]);
                }
            }
        }
    }

    function _liquidateLocal(
        LiquidationAction action,
        bytes calldata params,
        address[] calldata assets
    ) internal {
        // prettier-ignore
        (
            /* uint8 action */,
            address liquidateAccount,
            uint256 localCurrency,
            uint96 maxNTokenLiquidation
        ) = abi.decode(params, (uint8, address, uint256, uint96));

        if (_hasTransferFees(action)) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            uint256 amount = IERC20(assets[0]).balanceOf(address(this));
            checkAllowanceOrSet(assets[0], address(NotionalV2));
            NotionalV2.depositUnderlyingToken(address(this), uint16(localCurrency), amount);
        }

        // prettier-ignore
        (
            /* int256 localAssetCashFromLiquidator */,
            int256 netNTokens
        ) = NotionalV2.liquidateLocalCurrency(liquidateAccount, localCurrency, maxNTokenLiquidation);

        // Will withdraw entire cash balance. Don't redeem local currency here because it has been flash
        // borrowed and we need to redeem the entire balance to underlying for the flash loan repayment.
        _redeemAndWithdraw(localCurrency, uint96(netNTokens), false);
    }

    function _liquidateCollateral(
        LiquidationAction action,
        bytes calldata params,
        address[] calldata assets
    ) internal returns (address) {
        // prettier-ignore
        (
            /* uint8 action */,
            address liquidateAccount,
            uint256 localCurrency,
            uint256 collateralCurrency,
            uint128 maxCollateralLiquidation,
            uint96 maxNTokenLiquidation
        ) = abi.decode(params, (uint8, address, uint256, uint256, uint128, uint96));

        if (_hasTransferFees(action)) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            uint256 amount = IERC20(assets[0]).balanceOf(address(this));
            checkAllowanceOrSet(assets[0], address(NotionalV2));
            NotionalV2.depositUnderlyingToken(address(this), uint16(localCurrency), amount);
        }

        // prettier-ignore
        (
            /* int256 localAssetCashFromLiquidator */,
            /* int256 collateralAssetCash */,
            int256 collateralNTokens
        ) = NotionalV2.liquidateCollateralCurrency(
            liquidateAccount,
            localCurrency,
            collateralCurrency,
            maxCollateralLiquidation,
            maxNTokenLiquidation,
            true, // Withdraw collateral
            false // Redeem to underlying (will happen later)
        );

        // Redeem to underlying for collateral because it needs to be traded on the DEX
        _redeemAndWithdraw(collateralCurrency, uint96(collateralNTokens), true);

        // prettier-ignore
        (
            Token memory localAssetToken,
            Token memory localUnderlyingToken
        ) = NotionalV2.getCurrency(uint16(collateralCurrency));

        CErc20Interface(localAssetToken.tokenAddress).redeem(IERC20(localAssetToken.tokenAddress).balanceOf(address(this)));
        
        // Wrap everything to WETH for trading
        if (collateralCurrency == 1) WETH9(WETH).deposit{value: address(this).balance}();

        // Will withdraw all cash balance, no need to redeem local currency, it will be
        // redeemed later
        if (_hasTransferFees(action)) _redeemAndWithdraw(localCurrency, 0, false);

        return collateralCurrency == 1 ? WETH : localUnderlyingToken.tokenAddress;
    }

    function _liquidateLocalfCash(
        LiquidationAction action,
        bytes calldata params,
        address[] calldata assets
    ) internal {
        // prettier-ignore
        (
            /* uint8 action */,
            address liquidateAccount,
            uint256 localCurrency,
            uint256[] memory fCashMaturities,
            uint256[] memory maxfCashLiquidateAmounts
        ) = abi.decode(params, (uint8, address, uint256, uint256[], uint256[]));

        if (_hasTransferFees(action)) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            uint256 amount = IERC20(assets[0]).balanceOf(address(this));
            checkAllowanceOrSet(assets[0], address(NotionalV2));
            NotionalV2.depositUnderlyingToken(address(this), uint16(localCurrency), amount);
        }

        // prettier-ignore
        (
            int256[] memory fCashNotionalTransfers,
            int256 localAssetCashFromLiquidator
        ) = NotionalV2.liquidatefCashLocal(
            liquidateAccount,
            localCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts
        );

        // If localAssetCashFromLiquidator is negative (meaning the liquidator has received cash)
        // then when we will need to lend in order to net off the negative fCash. In this case we
        // will deposit the local asset cash back into notional.
        _sellfCashAssets(
            localCurrency,
            fCashMaturities,
            fCashNotionalTransfers,
            localAssetCashFromLiquidator < 0 ? uint256(localAssetCashFromLiquidator.abs()) : 0,
            false // No need to redeem to underlying here
        );

        // NOTE: no withdraw if _hasTransferFees, _sellfCashAssets with withdraw everything
    }

    function _liquidateCrossCurrencyfCash(
        LiquidationAction action,
        bytes calldata params,
        address[] calldata assets
    ) internal {
        // prettier-ignore
        (
            /* bytes1 action */,
            address liquidateAccount,
            uint256 localCurrency,
            uint256 fCashCurrency,
            uint256[] memory fCashMaturities,
            uint256[] memory maxfCashLiquidateAmounts
        ) = abi.decode(params, 
            (uint8, address, uint256, uint256, uint256[], uint256[])
        );

        if (_hasTransferFees(action)) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            uint256 amount = IERC20(assets[0]).balanceOf(address(this));
            checkAllowanceOrSet(assets[0], address(NotionalV2));
            NotionalV2.depositUnderlyingToken(address(this), uint16(localCurrency), amount);
        }

        // prettier-ignore
        (
            int256[] memory fCashNotionalTransfers,
            /* int256 localAssetCashFromLiquidator */
        ) = NotionalV2.liquidatefCashCrossCurrency(
            liquidateAccount,
            localCurrency,
            fCashCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts
        );

        // Redeem to underlying here, collateral is not specified as an input asset
        _sellfCashAssets(fCashCurrency, fCashMaturities, fCashNotionalTransfers, 0, true);
        // Wrap everything to WETH for trading
        if (fCashCurrency == 1) WETH9(WETH).deposit{value: address(this).balance}();

        // NOTE: no withdraw if _hasTransferFees, _sellfCashAssets with withdraw everything
    }

    function _hasTransferFees(LiquidationAction action) private pure returns (bool) {
        return (action == LiquidationAction.LocalCurrency_WithTransferFee ||
            action == LiquidationAction.CollateralCurrency_WithTransferFee ||
            action == LiquidationAction.LocalfCash_WithTransferFee ||
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee);
    }

    function _redeemCTokens(address[] calldata assets) internal {
        // Redeem cTokens to underlying to repay the flash loan
        for (uint256 i; i < assets.length; i++) {
            address cToken = assets[i] == WETH ? cETH : underlyingToCToken[assets[i]];
            if (cToken == address(0)) continue;

            CErc20Interface(cToken).redeem(IERC20(cToken).balanceOf(address(this)));
            // Wrap ETH into WETH for repayment
            if (assets[i] == WETH && address(this).balance > 0) {
                WETH9(WETH).deposit{value: address(this).balance}();
            }
        }
    }

    function _redeemAndWithdraw(
        uint256 nTokenCurrencyId,
        uint96 nTokenBalance,
        bool redeemToUnderlying
    ) internal {
        BalanceAction[] memory action = new BalanceAction[](1);
        // If nTokenBalance is zero still try to withdraw entire cash balance
        action[0].actionType = nTokenBalance == 0
            ? DepositActionType.None
            : DepositActionType.RedeemNToken;
        action[0].currencyId = uint16(nTokenCurrencyId);
        action[0].depositActionAmount = nTokenBalance;
        action[0].withdrawEntireCashBalance = true;
        action[0].redeemToUnderlying = redeemToUnderlying;
        NotionalV2.batchBalanceAction(address(this), action);
    }

    function _sellfCashAssets(
        uint256 fCashCurrency,
        uint256[] memory fCashMaturities,
        int256[] memory fCashNotional,
        uint256 depositActionAmount,
        bool redeemToUnderlying
    ) internal {
        uint256 blockTime = block.timestamp;
        BalanceActionWithTrades[] memory action = new BalanceActionWithTrades[](1);
        action[0].actionType = depositActionAmount > 0
            ? DepositActionType.DepositAsset
            : DepositActionType.None;
        action[0].depositActionAmount = depositActionAmount;
        action[0].currencyId = uint16(fCashCurrency);
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

    function checkAllowanceOrSet(address erc20, address spender) internal {
        if (IERC20(erc20).allowance(address(this), spender) < 2**128) {
            IERC20(erc20).approve(spender, type(uint256).max);
        }
    }

    function wrap() public {
        WETH9(WETH).deposit{value: address(this).balance}();
    }

    function withdraw(address token, uint256 amount) public {
        IERC20(token).transfer(OWNER, amount);
    }

    receive() external payable {}
}
