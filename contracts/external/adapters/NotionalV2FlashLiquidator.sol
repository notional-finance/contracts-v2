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

contract NotionalV2FlashLiquidator is IFlashLoanReceiver {
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
    address immutable OWNER;
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
        underlyingToCToken[underlying] = cToken;
    }

    function approveToken(address token, address spender) external onlyOwner {
        IERC20(token).approve(spender, type(uint256).max);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(initiator == OWNER); // dev: unauthorized caller
        require(msg.sender == LENDING_POOL); // dev: unauthorized caller

        // Mint cTokens for incoming assets, if required
        _mintCTokens(assets, amounts);

        LiquidationAction action = LiquidationAction(uint8(abi.decode(params, (bytes1))));
        address tradeContract;
        bytes memory tradeCallData;
        uint256 tradeETHValue;

        if (
            action == LiquidationAction.LocalCurrency_WithTransferFee ||
            action == LiquidationAction.LocalCurrency_NoTransferFee
        ) {
            _liquidateLocal(action, params, amounts);
        } else if (
            action == LiquidationAction.CollateralCurrency_WithTransferFee ||
            action == LiquidationAction.CollateralCurrency_NoTransferFee
        ) {
            (tradeContract, tradeCallData, tradeETHValue) = _liquidateCollateral(
                action,
                params,
                amounts
            );
        } else if (
            action == LiquidationAction.LocalfCash_WithTransferFee ||
            action == LiquidationAction.LocalfCash_NoTransferFee
        ) {
            _liquidateLocalfCash(action, params, amounts);
        } else if (
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee ||
            action == LiquidationAction.CrossCurrencyfCash_NoTransferFee
        ) {
            (tradeContract, tradeCallData, tradeETHValue) = _liquidateCrossCurrencyfCash(
                action,
                params,
                amounts
            );
        }

        _redeemCTokens(assets, amounts, premiums);

        if (tradeContract != address(0)) {
            // Arbitrary call to any DEX to trade back to local currency
            // prettier-ignore
            (
                bool success,
                /* return value */
            ) = tradeContract.call{value: tradeETHValue}(tradeCallData);
            require(success);
        }

        // The lending pool should have enough approval to pull the required amount from the contract
        return true;
    }

    function _mintCTokens(address[] calldata assets, uint256[] calldata amounts) internal {
        for (uint256 i; i < assets.length; i++) {
            if (assets[i] == WETH) {
                // Withdraw WETH to ETH and mint CEth
                WETH9(WETH).withdraw(amounts[i]);
                CEtherInterface(cETH).mint{value: amounts[i]}();
            } else {
                address cToken = underlyingToCToken[assets[i]];
                if (cToken != address(0)) CErc20Interface(cToken).mint(amounts[i]);
            }
        }
    }

    function _liquidateLocal(
        LiquidationAction action,
        bytes calldata params,
        uint256[] calldata amounts
    ) internal {
        // prettier-ignore
        (
            /* bytes1 action */,
            address liquidateAccount,
            uint256 localCurrency,
            uint96 maxNTokenLiquidation
        ) = abi.decode(params, (bytes1, address, uint256, uint96));

        if (_hasTransferFees(action)) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            NotionalV2.depositAssetToken(address(this), uint16(localCurrency), amounts[0]);
        }

        // prettier-ignore
        (
            int256 localAssetCashFromLiquidator,
            int256 netNTokens
        ) = NotionalV2.liquidateLocalCurrency(liquidateAccount, localCurrency, maxNTokenLiquidation);
        int256 redeemAssetCash = _redeemNToken(localCurrency, uint96(netNTokens));

        if (_hasTransferFees(action)) {
            int256 withdrawAmount = int256(amounts[0]).sub(localAssetCashFromLiquidator).add(
                redeemAssetCash
            );

            // NOTE: Don't redeem to underlying, this will happen later
            NotionalV2.withdraw(uint16(localCurrency), uint88(withdrawAmount), false);
        }
    }

    function _liquidateCollateral(
        LiquidationAction action,
        bytes calldata params,
        uint256[] calldata amounts
    )
        internal
        returns (
            address tradeContract,
            bytes memory tradeCallData,
            uint256 tradeETHValue
        )
    {
        uint256 localCurrency;
        uint256 collateralCurrency;
        address liquidateAccount;
        uint128 maxCollateralLiquidation;
        uint96 maxNTokenLiquidation;
        // prettier-ignore
        (
            /* bytes1 action */,
            liquidateAccount,
            localCurrency,
            collateralCurrency,
            maxCollateralLiquidation,
            maxNTokenLiquidation,
            tradeContract,
            tradeCallData,
            tradeETHValue
        ) = abi.decode(params, (bytes1, address, uint256, uint256, uint128, uint96, address, bytes, uint256));

        if (_hasTransferFees(action)) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            NotionalV2.depositAssetToken(address(this), uint16(localCurrency), amounts[0]);
        }

        // prettier-ignore
        (
            int256 localAssetCashFromLiquidator,
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

        _redeemNToken(collateralCurrency, uint96(collateralNTokens));

        if (_hasTransferFees(action)) {
            int256 withdrawAmount = int256(amounts[0]).sub(localAssetCashFromLiquidator);
            // NOTE: Don't redeem to underlying, this will happen later
            NotionalV2.withdraw(uint16(localCurrency), uint88(withdrawAmount), false);
        }
    }

    function _liquidateLocalfCash(
        LiquidationAction action,
        bytes calldata params,
        uint256[] calldata amounts
    ) internal {
        // prettier-ignore
        (
            /* bytes1 action */,
            address liquidateAccount,
            uint256 localCurrency,
            uint256[] memory fCashMaturities,
            uint256[] memory maxfCashLiquidateAmounts
        ) = abi.decode(params, (bytes1, address, uint256, uint256[], uint256[]));

        if (_hasTransferFees(action)) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            NotionalV2.depositAssetToken(address(this), uint16(localCurrency), amounts[0]);
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
            localAssetCashFromLiquidator < 0 ? uint256(localAssetCashFromLiquidator.abs()) : 0
        );

        // NOTE: no withdraw if _hasTransferFees, _sellfCashAssets with withdraw everything
    }

    function _liquidateCrossCurrencyfCash(
        LiquidationAction action,
        bytes calldata params,
        uint256[] calldata amounts
    )
        internal
        returns (
            address tradeContract,
            bytes memory tradeCallData,
            uint256 tradeETHValue
        )
    {
        address liquidateAccount;
        uint256 localCurrency;
        uint256 fCashCurrency;
        uint256[] memory fCashMaturities;
        uint256[] memory maxfCashLiquidateAmounts;
        // prettier-ignore
        (
            /* bytes1 action */,
            liquidateAccount,
            localCurrency,
            fCashCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts,
            tradeContract,
            tradeCallData,
            tradeETHValue
        ) = abi.decode(params, 
            (bytes1, address, uint256, uint256, uint256[], uint256[], address, bytes, uint256)
        );

        if (_hasTransferFees(action)) {
            // NOTE: This assumes that the first asset flash borrowed is the one with transfer fees
            NotionalV2.depositAssetToken(address(this), uint16(localCurrency), amounts[0]);
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

        _sellfCashAssets(fCashCurrency, fCashMaturities, fCashNotionalTransfers, 0);

        // NOTE: no withdraw if _hasTransferFees, _sellfCashAssets with withdraw everything
    }

    function _hasTransferFees(LiquidationAction action) private returns (bool) {
        return (action == LiquidationAction.LocalCurrency_WithTransferFee ||
            action == LiquidationAction.CollateralCurrency_WithTransferFee ||
            action == LiquidationAction.LocalfCash_WithTransferFee ||
            action == LiquidationAction.CrossCurrencyfCash_WithTransferFee);
    }

    function _redeemCTokens(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums
    ) internal {
        // Redeem cTokens to underlying to repay the flash loan
        for (uint256 i; i < assets.length; i++) {
            address cToken = assets[i] == WETH ? cETH : underlyingToCToken[assets[i]];
            uint256 repayAmount = amounts[i].add(premiums[i]);
            if (cToken != address(0)) {
                // Redeem the repayment required amount
                CErc20Interface(cToken).redeemUnderlying(repayAmount);
            }

            // Wrap back to WETH if needed
            if (assets[i] == WETH) WETH9(WETH).deposit{value: repayAmount}();
        }
    }

    function _redeemNToken(uint256 nTokenCurrencyId, uint96 nTokenBalance)
        internal
        returns (int256)
    {
        if (nTokenBalance == 0) return 0;
        return
            NotionalV2.nTokenRedeem(address(this), uint16(nTokenCurrencyId), nTokenBalance, true);
    }

    function _sellfCashAssets(
        uint256 fCashCurrency,
        uint256[] memory fCashMaturities,
        int256[] memory fCashNotional,
        uint256 depositActionAmount
    ) internal {
        uint256 blockTime = block.timestamp;
        BalanceActionWithTrades[] memory action = new BalanceActionWithTrades[](1);
        action[0].actionType = depositActionAmount > 0
            ? DepositActionType.DepositAsset
            : DepositActionType.None;
        action[0].depositActionAmount = depositActionAmount;
        action[0].currencyId = uint16(fCashCurrency);
        action[0].withdrawEntireCashBalance = true;
        action[0].redeemToUnderlying = false; // Don't redeem to underlying, this will happen later

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

    receive() external payable {}
}
