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
    )
        external
        override
        returns (bool)
    {
        require(initiator == OWNER); // dev: unauthorized caller
        require(msg.sender == LENDING_POOL); // dev: unauthorized caller

        // Mint cTokens for incoming assets, if required
        _mintCTokens(assets, amounts);

        (bytes1 action) = abi.decode(params, (bytes1));
        address tradeContract;
        bytes memory tradeCallData;
        uint256 tradeETHValue;
        if (action == 0x01) {
            // prettier-ignore
            (
                /* bytes1 action */,
                address liquidateAccount,
                uint256 localCurrency,
                uint96 maxNTokenLiquidation
            ) = abi.decode(params, (bytes1, address, uint256, uint96));

            (
                int256 localAssetCash,
                int256 netNTokens
            ) = NotionalV2.liquidateLocalCurrency(liquidateAccount, localCurrency, maxNTokenLiquidation);

            if (netNTokens > 0) _redeemNToken(localCurrency, uint96(netNTokens));
        } else if (action == 0x02) {
            address liquidateAccount;
            uint256 localCurrency;
            uint256 collateralCurrency;
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

            (
                /* localAssetCash */,
                int256 collateralAssetCash,
                int256 collateralNTokens
            ) = NotionalV2.liquidateCollateralCurrency(
                liquidateAccount,
                localCurrency,
                collateralCurrency,
                maxCollateralLiquidation,
                maxNTokenLiquidation,
                true, // Withdraw collateral
                true  // Redeem to underlying
            );

            if (collateralNTokens > 0) _redeemNToken(collateralCurrency, uint96(collateralNTokens));
        } else if (action == 0x03) {
            // prettier-ignore
            (
                /* bytes1 action */,
                address liquidateAccount,
                uint256 localCurrency,
                uint256[] memory fCashMaturities,
                uint256[] memory maxfCashLiquidateAmounts
            ) = abi.decode(params, (bytes1, address, uint256, uint256[], uint256[]));

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
        } else if (action == 0x04) {
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
        }

        _redeemCTokens(assets, amounts, premiums);

        if (tradeContract != address(0)) {
            // Arbitrary call to any DEX to trade back to local currency
            (bool success, /* return value */) = tradeContract.call{value: tradeETHValue}(tradeCallData);
            require(success);
        }

        // The lending pool should have enough approval to pull the required amount from the contract
        return true;
    }

    function _mintCTokens(address[] calldata assets, uint256[] calldata amounts) internal {
        for (uint i; i < assets.length; i++) {
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

    function _redeemCTokens(address[] calldata assets, uint256[] calldata amounts, uint256[] calldata premiums) internal {
        // Redeem cTokens to underlying to repay the flash loan
        for (uint i; i < assets.length; i++) {
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

    function _redeemNToken(uint256 nTokenCurrencyId, uint96 nTokenBalance) internal {
        return NotionalV2.nTokenRedeem(address(this), uint16(nTokenCurrencyId), nTokenBalance, true);
    }

    function _sellfCashAssets(
        uint256 fCashCurrency,
        uint256[] memory fCashMaturities,
        int256[] memory fCashNotional,
        uint256 depositActionAmount
    ) internal {
        uint blockTime = block.timestamp;
        BalanceActionWithTrades[] memory action = new BalanceActionWithTrades[](1);
        action[0].actionType = depositActionAmount > 0 ? DepositActionType.DepositAsset: DepositActionType.None;
        action[0].depositActionAmount = depositActionAmount;
        action[0].currencyId = uint16(fCashCurrency);
        action[0].withdrawEntireCashBalance = true;
        action[0].redeemToUnderlying = true;

        uint256 numTrades;
        bytes32[] memory trades = new bytes32[](fCashMaturities.length);
        for (uint i; i < fCashNotional.length; i++) {
            if (fCashNotional[i] == 0) continue;
            (uint marketIndex, bool isIdiosyncratic) = DateTime.getMarketIndex(7, fCashMaturities[i], blockTime);
            // We don't trade it out here but if the contract does take on idiosyncratic cash we need to be careful
            if (isIdiosyncratic) continue;

            trades[numTrades] = bytes32(
                (uint256(fCashNotional[i] > 0 ? TradeActionType.Borrow : TradeActionType.Lend) << 248) |
                (marketIndex << 240) |
                (uint256(uint88(fCashNotional[i].abs())) << 152)
            );
            numTrades++;
        }

        if (numTrades < trades.length) {
            // Shrink the trades array to length if it is not full
            bytes32[] memory newTrades = new bytes32[](numTrades);
            for (uint i; i < numTrades; i++) {
                newTrades[i] = trades[i];
            }
            action[0].trades = newTrades;
        } else {
            action[0].trades = trades;
        }

        NotionalV2.batchBalanceAndTradeAction(address(this), action);
    }
}