// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "./actions/nTokenMintAction.sol";
import "../internal/balances/TokenHandler.sol";
import "../global/StorageLayoutV1.sol";
import "../internal/markets/CashGroup.sol";
import "../internal/markets/AssetRate.sol";
import "../internal/nToken/nTokenSupply.sol";
import "../internal/nToken/nTokenHandler.sol";
import "../math/SafeInt256.sol";
import "../../interfaces/notional/NotionalCalculations.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract CalculationViews is StorageLayoutV1, NotionalCalculations {
    using TokenHandler for Token;
    using Market for MarketParameters;
    using AssetRate for AssetRateParameters;
    using CashGroup for CashGroupParameters;
    using nTokenHandler for nTokenPortfolio;
    using AccountContextHandler for AccountContext;
    using BalanceHandler for BalanceState;
    using SafeInt256 for int256;
    using SafeMath for uint256;

    function _checkValidCurrency(uint16 currencyId) internal view {
        require(0 < currencyId && currencyId <= maxCurrencyId, "Invalid currency id");
    }

    /** General Calculation View Methods **/

    /// @notice Returns the nTokens that will be minted when some amount of asset tokens are deposited
    /// @param currencyId id number of the currency
    /// @param amountToDepositExternalPrecision amount of asset tokens in native precision
    /// @return the amount of nTokens that will be minted
    function calculateNTokensToMint(uint16 currencyId, uint88 amountToDepositExternalPrecision)
        external
        view
        override
        returns (uint256)
    {
        _checkValidCurrency(currencyId);
        Token memory token = TokenHandler.getAssetToken(currencyId);
        int256 amountToDepositInternal = token.convertToInternal(int256(amountToDepositExternalPrecision));
        nTokenPortfolio memory nToken;
        nToken.loadNTokenPortfolioView(currencyId);

        int256 tokensToMint = nTokenMintAction.calculateTokensToMint(
            nToken,
            amountToDepositInternal,
            block.timestamp
        );

        return SafeCast.toUint256(tokensToMint);
    }


    /// @notice Returns the fCash amount to send when given a cash amount, be sure to buffer these amounts
    /// slightly because the liquidity curve is sensitive to changes in block time
    /// @param currencyId id number of the currency
    /// @param netCashToAccount denominated in underlying terms in 1e8 decimal precision,
    //// positive for borrowing, negative for lending
    /// @param marketIndex market index of the fCash market
    /// @param blockTime the block time for when the trade will be calculated
    /// @return the fCash amount from the trade, positive when lending, negative when borrowing. Always in 8 decimals.
    function getfCashAmountGivenCashAmount(
        uint16 currencyId,
        int88 netCashToAccount,
        uint256 marketIndex,
        uint256 blockTime
    ) external view override returns (int256) {
        _checkValidCurrency(currencyId);
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        return _getfCashAmountGivenCashAmount(netCashToAccount, marketIndex, blockTime, cashGroup);
    }
        
    function _getfCashAmountGivenCashAmount(
        int88 netCashToAccount,
        uint256 marketIndex,
        uint256 blockTime,
        CashGroupParameters memory cashGroup
    ) internal view returns (int256) {
        MarketParameters memory market;
        cashGroup.loadMarket(market, marketIndex, false, blockTime);

        require(market.maturity > blockTime, "Invalid block time");
        uint256 timeToMaturity = market.maturity - blockTime;
        (int256 rateScalar, int256 totalCashUnderlying, int256 rateAnchor) =
            Market.getExchangeRateFactors(market, cashGroup, timeToMaturity, marketIndex);
        int256 fee = Market.getExchangeRateFromImpliedRate(cashGroup.getTotalFee(), timeToMaturity);

        return
            Market.getfCashGivenCashAmount(
                market.totalfCash,
                netCashToAccount,
                totalCashUnderlying,
                rateScalar,
                rateAnchor,
                fee,
                0
            );
    }

    /// @notice Returns the cash amount that will be traded given an fCash amount, be sure to buffer these amounts
    /// slightly because the liquidity curve is sensitive to changes in block time
    /// @param currencyId id number of the currency
    /// @param fCashAmount amount of fCash to trade, negative for borrowing, positive for lending
    /// @param marketIndex market index of the fCash market
    /// @param blockTime the block time for when the trade will be calculated
    /// @return net asset cash amount (positive for borrowing, negative for lending) in 8 decimal precision
    /// @return underlying cash amount (positive for borrowing, negative for lending) in 8 decimal precision
    function getCashAmountGivenfCashAmount(
        uint16 currencyId,
        int88 fCashAmount,
        uint256 marketIndex,
        uint256 blockTime
    ) external view override returns (int256, int256) {
        return _getCashAmountGivenfCashAmount(currencyId, fCashAmount, marketIndex, blockTime, 0);
    }

    function _getCashAmountGivenfCashAmount(
        uint16 currencyId,
        int88 fCashAmount,
        uint256 marketIndex,
        uint256 blockTime, 
        uint256 rateLimit
    ) internal view returns (int256, int256) {
        _checkValidCurrency(currencyId);
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupView(currencyId);
        MarketParameters memory market;
        cashGroup.loadMarket(market, marketIndex, false, blockTime);

        require(market.maturity > blockTime, "Invalid block time");
        uint256 timeToMaturity = market.maturity - blockTime;

        // prettier-ignore
        (int256 assetCash, /* int fee */) =
            market.calculateTrade(cashGroup, fCashAmount, timeToMaturity, marketIndex);

        // Check the slippage here and revert
        if (rateLimit != 0) {
            if (fCashAmount < 0) {
                // Do not allow borrows over the rate limit
                require(market.lastImpliedRate <= rateLimit, "Trade failed, slippage");
            } else {
                // Do not allow lends under the rate limit
                require(market.lastImpliedRate >= rateLimit, "Trade failed, slippage");
            }
        }

        return (assetCash, cashGroup.assetRate.convertToUnderlying(assetCash));
    }

    /// @notice Returns the claimable incentives for all nToken balances
    /// @param account The address of the account which holds the tokens
    /// @param blockTime The block time when incentives will be minted
    /// @return Incentives an account is eligible to claim
    function nTokenGetClaimableIncentives(address account, uint256 blockTime)
        external
        view
        override
        returns (uint256)
    {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState memory balanceState;
        uint256 totalIncentivesClaimable;

        if (accountContext.isBitmapEnabled()) {
            balanceState.loadBalanceState(account, accountContext.bitmapCurrencyId, accountContext);
            if (balanceState.storedNTokenBalance > 0) {
                address tokenAddress = nTokenHandler.nTokenAddress(balanceState.currencyId);
                (
                    /* uint256 totalSupply */,
                    uint256 accumulatedNOTEPerNToken,
                    /* uint256 lastAccumulatedTime */
                ) = nTokenSupply.getUpdatedAccumulatedNOTEPerNToken(tokenAddress, blockTime);

                uint256 incentivesToClaim = Incentives.calculateIncentivesToClaim(
                    balanceState,
                    tokenAddress,
                    accumulatedNOTEPerNToken,
                    balanceState.storedNTokenBalance.toUint()
                );
                totalIncentivesClaimable = totalIncentivesClaimable.add(incentivesToClaim);
            }
        }

        bytes18 currencies = accountContext.activeCurrencies;
        while (currencies != 0) {
            uint16 currencyId = uint16(bytes2(currencies) & Constants.UNMASK_FLAGS);
            balanceState.loadBalanceState(account, currencyId, accountContext);

            if (balanceState.storedNTokenBalance > 0) {
                address tokenAddress = nTokenHandler.nTokenAddress(balanceState.currencyId);
                (
                    /* uint256 totalSupply */,
                    uint256 accumulatedNOTEPerNToken,
                    /* uint256 lastAccumulatedTime */
                ) = nTokenSupply.getUpdatedAccumulatedNOTEPerNToken(tokenAddress, blockTime);

                uint256 incentivesToClaim = Incentives.calculateIncentivesToClaim(
                    balanceState,
                    tokenAddress,
                    accumulatedNOTEPerNToken,
                    balanceState.storedNTokenBalance.toUint()
                );
                totalIncentivesClaimable = totalIncentivesClaimable.add(incentivesToClaim);
            }

            currencies = currencies << 16;
        }

        return totalIncentivesClaimable;
    }

    /// @notice Returns the present value of the given fCash amount using Notional internal oracle rates
    /// @param currencyId id number of the currency
    /// @param maturity timestamp of the fCash maturity
    /// @param notional amount of fCash notional
    /// @param blockTime the block time for when the trade will be calculated
    /// @param riskAdjusted true if haircuts and buffers should be applied to the oracle rate
    /// @return presentValue of fCash in 8 decimal precision and underlying denomination
    function getPresentfCashValue(
        uint16 currencyId,
        uint256 maturity,
        int256 notional,
        uint256 blockTime,
        bool riskAdjusted
    ) external view override returns (int256 presentValue) {
        CashGroupParameters memory cg = CashGroup.buildCashGroupView(currencyId);
        if (riskAdjusted) {
            presentValue = AssetHandler.getRiskAdjustedPresentfCashValue(
                cg,
                notional,
                maturity,
                blockTime,
                cg.calculateOracleRate(maturity, blockTime)
            );
        } else {
            presentValue = AssetHandler.getPresentfCashValue(
                notional,
                maturity,
                blockTime,
                cg.calculateOracleRate(maturity, blockTime)
            );
        }
    }

    /// @notice Returns a market index value for a given maturity
    /// @param maturity an fCash maturity
    /// @param blockTime the block time for when the trade will be calculated
    /// @return marketIndex a value between 1 and 7 that represents the marketIndex (tenor)
    /// that corresponds to the maturity. Returns 0 if there is no corresponding marketIndex
    function getMarketIndex(
        uint256 maturity,
        uint256 blockTime
    ) public pure override returns (uint8 marketIndex) {
        (
            uint256 _marketIndex,
            bool isIdiosyncratic
        ) = DateTime.getMarketIndex(Constants.MAX_TRADED_MARKET_INDEX, maturity, blockTime);

        // Market Index cannot be greater than 7 by construction
        marketIndex = isIdiosyncratic ? 0 : uint8(_marketIndex);
    }

    /// @notice Returns the amount of fCash that would received if lending deposit amount.
    /// @param currencyId id number of the currency
    /// @param depositAmountExternal amount to deposit in the token's native precision. For aTokens use
    /// what is returned by the balanceOf selector (not scaledBalanceOf).
    /// @param maturity the maturity of the fCash to lend
    /// @param minLendRate the minimum lending rate (slippage protection)
    /// @param blockTime the block time for when the trade will be calculated
    /// @param useUnderlying true if specifying the underlying token, false if specifying the asset token
    /// @return fCashAmount the amount of fCash that the lender will receive
    /// @return marketIndex the corresponding market index for the lending
    /// @return encodedTrade the encoded bytes32 object to pass to batch trade
    function getfCashLendFromDeposit(
        uint16 currencyId,
        uint256 depositAmountExternal,
        uint256 maturity,
        uint32 minLendRate,
        uint256 blockTime,
        bool useUnderlying
    ) external view override returns (
        uint88 fCashAmount,
        uint8 marketIndex,
        bytes32 encodedTrade
    ) {
        marketIndex = getMarketIndex(maturity, blockTime);
        require(marketIndex > 0);

        (
            int256 underlyingInternal,
            CashGroupParameters memory cashGroup
        ) = _convertDepositAmountToUnderlyingInternal(currencyId, depositAmountExternal, useUnderlying);
        int256 fCash = _getfCashAmountGivenCashAmount(_safeInt88(underlyingInternal.neg()), marketIndex, blockTime, cashGroup);
        require(0 < fCash);

        (
            encodedTrade,
            fCashAmount
        ) = _encodeLendBorrowTrade(TradeActionType.Lend, marketIndex, fCash, minLendRate);
    }

    /// @notice Returns the amount of fCash that would received if lending deposit amount.
    /// @param currencyId id number of the currency
    /// @param borrowedAmountExternal amount to borrow in the token's native precision. For aTokens use
    /// what is returned by the balanceOf selector (not scaledBalanceOf).
    /// @param maturity the maturity of the fCash to lend
    /// @param maxBorrowRate the maximum borrow rate (slippage protection). If zero then no slippage will be applied
    /// @param blockTime the block time for when the trade will be calculated
    /// @param useUnderlying true if specifying the underlying token, false if specifying the asset token
    /// @return fCashDebt the amount of fCash that the borrower will owe, this will be stored as a negative
    /// balance in Notional
    /// @return marketIndex the corresponding market index for the lending
    /// @return encodedTrade the encoded bytes32 object to pass to batch trade
    function getfCashBorrowFromPrincipal(
        uint16 currencyId,
        uint256 borrowedAmountExternal,
        uint256 maturity,
        uint32 maxBorrowRate,
        uint256 blockTime,
        bool useUnderlying
    ) external view override returns (
        uint88 fCashDebt,
        uint8 marketIndex,
        bytes32 encodedTrade
    ) {
        marketIndex = getMarketIndex(maturity, blockTime);
        require(marketIndex > 0);

        (
            int256 underlyingInternal,
            CashGroupParameters memory cashGroup
        ) = _convertDepositAmountToUnderlyingInternal(currencyId, borrowedAmountExternal, useUnderlying);
        int256 fCash = _getfCashAmountGivenCashAmount(_safeInt88(underlyingInternal), marketIndex, blockTime, cashGroup);
        require(fCash < 0);

        (
            encodedTrade,
            fCashDebt
        ) = _encodeLendBorrowTrade(TradeActionType.Borrow, marketIndex, fCash, maxBorrowRate);
    }

    /// @notice Returns the amount of underlying cash and asset cash required to lend fCash. When specifying a
    /// trade, deposit either underlying or asset tokens (not both). Asset tokens tend to be more gas efficient.
    /// @param currencyId id number of the currency
    /// @param fCashAmount amount of fCash (in underlying) that will be received at maturity. Always 8 decimal precision.
    /// @param maturity the maturity of the fCash to lend
    /// @param minLendRate the minimum lending rate (slippage protection)
    /// @param blockTime the block time for when the trade will be calculated
    /// @return depositAmountUnderlying the amount of underlying tokens the lender must deposit
    /// @return depositAmountAsset the amount of asset tokens the lender must deposit
    /// @return marketIndex the corresponding market index for the lending
    /// @return encodedTrade the encoded bytes32 object to pass to batch trade
    function getDepositFromfCashLend(
        uint16 currencyId,
        uint256 fCashAmount,
        uint256 maturity,
        uint32 minLendRate,
        uint256 blockTime
    ) external view override returns (
        uint256 depositAmountUnderlying,
        uint256 depositAmountAsset,
        uint8 marketIndex,
        bytes32 encodedTrade
    ) {
        marketIndex = getMarketIndex(maturity, blockTime);
        require(marketIndex > 0);
        require(fCashAmount < uint256(int256(type(int88).max)));

        int88 fCash = int88(SafeInt256.toInt(fCashAmount));
        (
            int256 assetCashInternal,
            int256 underlyingCashInternal
        ) = _getCashAmountGivenfCashAmount(currencyId, fCash, marketIndex, blockTime, minLendRate);

        depositAmountUnderlying = _convertToAmountExternal(currencyId, underlyingCashInternal, true);
        depositAmountAsset = _convertToAmountExternal(currencyId, assetCashInternal, false);
        (encodedTrade, /* */) = _encodeLendBorrowTrade(TradeActionType.Lend, marketIndex, fCash, minLendRate);
    }

    /// @notice Returns the amount of underlying cash and asset cash required to borrow fCash. When specifying a
    /// trade, choose to receive either underlying or asset tokens (not both). Asset tokens tend to be more gas efficient.
    /// @param currencyId id number of the currency
    /// @param fCashBorrow amount of fCash (in underlying) that will be received at maturity. Always 8 decimal precision.
    /// @param maturity the maturity of the fCash to lend
    /// @param maxBorrowRate the maximum borrow rate (slippage protection)
    /// @param blockTime the block time for when the trade will be calculated
    /// @return borrowAmountUnderlying the amount of underlying tokens the borrower will receive
    /// @return borrowAmountAsset the amount of asset tokens the borrower will receive
    /// @return marketIndex the corresponding market index for the lending
    /// @return encodedTrade the encoded bytes32 object to pass to batch trade
    function getPrincipalFromfCashBorrow(
        uint16 currencyId,
        uint256 fCashBorrow,
        uint256 maturity,
        uint32 maxBorrowRate,
        uint256 blockTime
    ) external view override returns (
        uint256 borrowAmountUnderlying,
        uint256 borrowAmountAsset,
        uint8 marketIndex,
        bytes32 encodedTrade
    ) {
        marketIndex = getMarketIndex(maturity, blockTime);
        require(marketIndex > 0);
        require(fCashBorrow < uint256(int256(type(int88).max)));

        int88 fCash = int88(SafeInt256.toInt(fCashBorrow).neg());
        (
            int256 assetCashInternal,
            int256 underlyingCashInternal
        ) = _getCashAmountGivenfCashAmount(currencyId, fCash, marketIndex, blockTime, maxBorrowRate);

        borrowAmountUnderlying = _convertToAmountExternal(currencyId, underlyingCashInternal, true);
        borrowAmountAsset = _convertToAmountExternal(currencyId, assetCashInternal, false);
        (encodedTrade, /* */) = _encodeLendBorrowTrade(TradeActionType.Borrow, marketIndex, fCash, maxBorrowRate);
    }

    /// @notice Converts an internal cash balance to an external token denomination
    /// @param currencyId the currency id of the cash balance
    /// @param cashBalanceInternal the signed cash balance that is stored in Notional
    /// @param convertToUnderlying true if the value should be converted to underlying
    /// @return the cash balance converted to the external token denomination
    function convertCashBalanceToExternal(
        uint16 currencyId,
        int256 cashBalanceInternal,
        bool convertToUnderlying
    ) external view override returns (int256) {
        if (convertToUnderlying) {
            AssetRateParameters memory ar = AssetRate.buildAssetRateView(currencyId);
            cashBalanceInternal = ar.convertToUnderlying(cashBalanceInternal);
        }

        int256 externalAmount = SafeInt256.toInt(_convertToAmountExternal(currencyId, cashBalanceInternal.abs(), convertToUnderlying));
        return cashBalanceInternal < 0 ? externalAmount.neg() : externalAmount;
    }

    function _convertToAmountExternal(
        uint16 currencyId,
        int256 depositAmountInternal,
        bool useUnderlying
    ) private view returns (uint256) {
        int256 amountExternal;
        Token memory token = useUnderlying ?
            TokenHandler.getUnderlyingToken(currencyId) :
            TokenHandler.getAssetToken(currencyId);

        if (useUnderlying && depositAmountInternal < 0) {
            // We have to do a special rounding adjustment for underlying internal deposits from lending.
            amountExternal = token.convertToUnderlyingExternalWithAdjustment(depositAmountInternal.neg());
        } else {
            amountExternal = token.convertToExternal(depositAmountInternal).abs();
        }

        if (token.tokenType == TokenType.aToken) {
            // Special handling for aTokens, we use scaled balance internally
            Token memory underlying = TokenHandler.getUnderlyingToken(currencyId);
            amountExternal = AaveHandler.convertFromScaledBalanceExternal(underlying.tokenAddress, amountExternal);
        }

        return SafeInt256.toUint(amountExternal);
    }

    /// @notice Converts an external deposit amount to an internal deposit amount
    function _convertDepositAmountToUnderlyingInternal(
        uint16 currencyId,
        uint256 depositAmountExternal,
        bool useUnderlying
    ) private view returns (int256 underlyingInternal, CashGroupParameters memory cashGroup) {
        int256 depositAmount = SafeInt256.toInt(depositAmountExternal);
        cashGroup = CashGroup.buildCashGroupView(currencyId);

        Token memory token = useUnderlying ?
            TokenHandler.getUnderlyingToken(currencyId) :
            TokenHandler.getAssetToken(currencyId);

        if (token.tokenType == TokenType.aToken) {
            // Special handling for aTokens, we use scaled balance internally
            depositAmount = AaveHandler.convertToScaledBalanceExternal(currencyId, depositAmount);
        }

        underlyingInternal = token.convertToInternal(depositAmount);
        if (!useUnderlying) {
            // Convert asset rates to underlying internal amounts
            underlyingInternal = cashGroup.assetRate.convertToUnderlying(underlyingInternal);
        }
    }

    function _safeInt88(int256 x) private pure returns (int88) {
        require(type(int88).min <= x && x <= type(int88).max);
        return int88(x);
    }

    function _encodeLendBorrowTrade(
        TradeActionType actionType,
        uint8 marketIndex,
        int256 fCash,
        uint32 slippage
    ) private pure returns (bytes32 encodedTrade, uint88 fCashAmount) {
        uint256 absfCash = uint256(fCash.abs());
        require(absfCash <= uint256(type(uint88).max));

        encodedTrade = bytes32(
            (uint256(uint8(actionType)) << 248) |
            (uint256(marketIndex) << 240) |
            (uint256(absfCash) << 152) |
            (uint256(slippage) << 120)
        );

        fCashAmount = uint88(absfCash);
    }

    /// @notice Get a list of deployed library addresses (sorted by library name)
    function getLibInfo() external pure returns (address) {
        return (address(MigrateIncentives));
    }
}