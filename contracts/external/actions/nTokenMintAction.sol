// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    PrimeRate,
    BalanceState,
    CashGroupParameters,
    MarketParameters,
    nTokenPortfolio,
    PortfolioState,
    PortfolioAsset,
    AssetStorageState
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {Bitmap} from "../../math/Bitmap.sol";

import {Emitter} from "../../internal/Emitter.sol";
import {DateTime} from "../../internal/markets/DateTime.sol";
import {nTokenHandler} from "../../internal/nToken/nTokenHandler.sol";
import {nTokenCalculations} from "../../internal/nToken/nTokenCalculations.sol";
import {InterestRateCurve} from "../../internal/markets/InterestRateCurve.sol";
import {Market} from "../../internal/markets/Market.sol";
import {CashGroup} from "../../internal/markets/CashGroup.sol";
import {PrimeRateLib} from "../../internal/pCash/PrimeRateLib.sol";
import {BalanceHandler} from "../../internal/balances/BalanceHandler.sol";
import {PortfolioHandler} from "../../internal/portfolio/PortfolioHandler.sol";
import {BitmapAssetsHandler} from "../../internal/portfolio/BitmapAssetsHandler.sol";
import {AssetHandler} from "../../internal/valuation/AssetHandler.sol";

library nTokenMintAction {
    using Bitmap for bytes32;
    using SafeInt256 for int256;
    using SafeUint256 for uint256;
    using BalanceHandler for BalanceState;
    using CashGroup for CashGroupParameters;
    using Market for MarketParameters;
    using nTokenHandler for nTokenPortfolio;
    using PortfolioHandler for PortfolioState;
    using PrimeRateLib for PrimeRate;

    event SweepCashIntoMarkets(uint16 currencyId, int256 cashIntoMarkets);

    /// @notice Converts the given amount of cash to nTokens in the same currency.
    /// @param currencyId the currency associated the nToken
    /// @param primeCashToDeposit the amount of asset tokens to deposit denominated in internal decimals
    /// @return nTokens minted by this action
    function nTokenMint(address account, uint16 currencyId, int256 primeCashToDeposit) external returns (int256) {
        return _nTokenMint(account, currencyId, primeCashToDeposit);
    }

    function sweepCashIntoMarkets(uint16 currencyId) external {
        nTokenPortfolio memory nToken;
        nToken.loadNTokenPortfolioStateful(currencyId);
        require(nToken.portfolioState.storedAssets.length > 0);

        // Can only sweep cash after markets have been initialized
        uint256 referenceTime = DateTime.getReferenceTime(block.timestamp);
        require(nToken.lastInitializedTime >= referenceTime);

        // Can only sweep cash after the residual purchase time has passed
        uint256 minSweepCashTime =
            nToken.lastInitializedTime.add(
                uint256(uint8(nToken.parameters[Constants.RESIDUAL_PURCHASE_TIME_BUFFER])) * 1 hours
            );
        require(block.timestamp > minSweepCashTime);

        int256 primeCashWithholding = getNTokenNegativefCashWithholding(
            nToken,
            new MarketParameters[](0), // Parameter is unused when referencing current markets
            block.timestamp
        );

        int256 cashIntoMarkets = nToken.cashBalance.subNoNeg(primeCashWithholding);
        BalanceHandler.setBalanceStorageForNToken(
            nToken.tokenAddress,
            nToken.cashGroup.currencyId,
            primeCashWithholding
        );

        // This will deposit the cash balance into markets, but will not record a token supply change.
        _nTokenMint(nToken.tokenAddress, currencyId, cashIntoMarkets);
        emit SweepCashIntoMarkets(currencyId, cashIntoMarkets);
    }

    function _nTokenMint(address account, uint16 currencyId, int256 primeCashToDeposit) internal returns (int256) {
        uint256 blockTime = block.timestamp;
        nTokenPortfolio memory nToken;
        nToken.loadNTokenPortfolioStateful(currencyId);

        int256 tokensToMint = calculateTokensToMint(nToken, primeCashToDeposit, blockTime);
        require(tokensToMint >= 0, "Invalid token amount");

        if (nToken.portfolioState.storedAssets.length == 0) {
            // If the token does not have any assets, then the markets must be initialized first.
            nToken.cashBalance = nToken.cashBalance.add(primeCashToDeposit);
            BalanceHandler.setBalanceStorageForNToken(
                nToken.tokenAddress,
                currencyId,
                nToken.cashBalance
            );
        } else {
            _depositIntoPortfolio(nToken, primeCashToDeposit, blockTime);
        }

        if (account != nToken.tokenAddress) {
            // If account == nToken.tokenAddress, this is due to a call to sweepCashIntoMarkets
            // and there will be no net nToken supply change.
            Emitter.emitNTokenMint(account, nToken.tokenAddress, currencyId, primeCashToDeposit, tokensToMint);
        }

        // NOTE: token supply does not change here, it will change after incentives have been claimed
        // during BalanceHandler.finalize
        return tokensToMint;
    }

    /// @notice Calculates the tokens to mint to the account as a ratio of the nToken
    /// present value denominated in asset cash terms.
    /// @return the amount of tokens to mint, the ifCash bitmap
    function calculateTokensToMint(
        nTokenPortfolio memory nToken,
        int256 primeCashToDeposit,
        uint256 blockTime
    ) internal view returns (int256) {
        require(primeCashToDeposit >= 0); // dev: deposit amount negative
        if (primeCashToDeposit == 0) return 0;

        if (nToken.lastInitializedTime != 0) {
            // For the sake of simplicity, nTokens cannot be minted if they have assets
            // that need to be settled. This is only done during market initialization.
            uint256 nextSettleTime = nToken.getNextSettleTime();
            // If next settle time <= blockTime then the token can be settled
            require(nextSettleTime > blockTime, "Requires settlement");
        }

        int256 primeCashPV = nTokenCalculations.getNTokenPrimePV(nToken, blockTime);
        // Defensive check to ensure PV remains positive
        require(primeCashPV >= 0);

        // Allow for the first deposit
        if (nToken.totalSupply == 0) {
            return primeCashToDeposit;
        } else {
            // primeCashPVPost = primeCashPV + amountToDeposit
            // (tokenSupply + tokensToMint) / tokenSupply == (primeCashPV + amountToDeposit) / primeCashPV
            // (tokenSupply + tokensToMint) == (primeCashPV + amountToDeposit) * tokenSupply / primeCashPV
            // (tokenSupply + tokensToMint) == tokenSupply + (amountToDeposit * tokenSupply) / primeCashPV
            // tokensToMint == (amountToDeposit * tokenSupply) / primeCashPV
            return primeCashToDeposit.mul(nToken.totalSupply).div(primeCashPV);
        }
    }

    /// @notice Portions out primeCashDeposit into amounts to deposit into individual markets. When
    /// entering this method we know that primeCashDeposit is positive and the nToken has been
    /// initialized to have liquidity tokens.
    function _depositIntoPortfolio(
        nTokenPortfolio memory nToken,
        int256 primeCashDeposit,
        uint256 blockTime
    ) private {
        (int256[] memory depositShares, int256[] memory leverageThresholds) =
            nTokenHandler.getDepositParameters(
                nToken.cashGroup.currencyId,
                nToken.cashGroup.maxMarketIndex
            );

        // Loop backwards from the last market to the first market, the reasoning is a little complicated:
        // If we have to deleverage the markets (i.e. lend instead of provide liquidity) it's quite gas inefficient
        // to calculate the cash amount to lend. We do know that longer term maturities will have more
        // slippage and therefore the residual from the perMarketDeposit will be lower as the maturities get
        // closer to the current block time. Any residual cash from lending will be rolled into shorter
        // markets as this loop progresses.
        int256 residualCash;
        MarketParameters memory market;
        for (uint256 marketIndex = nToken.cashGroup.maxMarketIndex; marketIndex > 0; marketIndex--) {
            int256 fCashAmount;
            // Loads values into the market memory slot
            nToken.cashGroup.loadMarket(
                market,
                marketIndex,
                true, // Needs liquidity to true
                blockTime
            );
            // If market has not been initialized, continue. This can occur when cash groups extend maxMarketIndex
            // before initializing
            if (market.totalLiquidity == 0) continue;

            // Checked that primeCashDeposit must be positive before entering
            int256 perMarketDeposit =
                primeCashDeposit
                    .mul(depositShares[marketIndex - 1])
                    .div(Constants.DEPOSIT_PERCENT_BASIS)
                    .add(residualCash);

            (fCashAmount, residualCash) = _lendOrAddLiquidity(
                nToken,
                market,
                perMarketDeposit,
                leverageThresholds[marketIndex - 1],
                marketIndex,
                blockTime
            );

            if (fCashAmount != 0) {
                BitmapAssetsHandler.addifCashAsset(
                    nToken.tokenAddress,
                    nToken.cashGroup.currencyId,
                    market.maturity,
                    nToken.lastInitializedTime,
                    fCashAmount
                );
            }
        }

        // nToken is allowed to store assets directly without updating account context.
        nToken.portfolioState.storeAssets(nToken.tokenAddress);

        // Defensive check to ensure that we do not somehow accrue negative residual cash.
        require(residualCash >= 0, "Negative residual cash");
        // This will occur if the three month market is over levered and we cannot lend into it
        if (residualCash > 0) {
            // Any remaining residual cash will be put into the nToken balance and added as liquidity on the
            // next market initialization
            nToken.cashBalance = nToken.cashBalance.add(residualCash);
            BalanceHandler.setBalanceStorageForNToken(
                nToken.tokenAddress,
                nToken.cashGroup.currencyId,
                nToken.cashBalance
            );
        }
    }

    /// @notice For a given amount of cash to deposit, decides how much to lend or provide
    /// given the market conditions.
    function _lendOrAddLiquidity(
        nTokenPortfolio memory nToken,
        MarketParameters memory market,
        int256 perMarketDeposit,
        int256 leverageThreshold,
        uint256 marketIndex,
        uint256 blockTime
    ) private returns (int256 fCashAmount, int256 residualCash) {
        // We start off with the entire per market deposit as residuals
        residualCash = perMarketDeposit;

        // If the market is over leveraged then we will lend to it instead of providing liquidity
        if (_isMarketOverLeveraged(nToken.cashGroup, market, leverageThreshold)) {
            (residualCash, fCashAmount) = _deleverageMarket(
                nToken.cashGroup,
                market,
                perMarketDeposit,
                blockTime,
                marketIndex,
                nToken.tokenAddress
            );

            // Recalculate this after lending into the market, if it is still over leveraged then
            // we will not add liquidity and just exit.
            if (_isMarketOverLeveraged(nToken.cashGroup, market, leverageThreshold)) {
                // Returns the residual cash amount
                return (fCashAmount, residualCash);
            }
        }

        // Add liquidity to the market only if we have successfully delevered.
        // (marketIndex - 1) is the index of the nToken portfolio array where the asset is stored
        // If deleveraged, residualCash is what remains
        // If not deleveraged, residual cash is per market deposit
        fCashAmount = fCashAmount.add(
            _addLiquidityToMarket(nToken, market, marketIndex - 1, residualCash)
        );
        // No residual cash if we're adding liquidity
        return (fCashAmount, 0);
    }

    /// @notice Markets are over levered when their proportion is greater than a governance set
    /// threshold. At this point, providing liquidity will incur too much negative fCash on the nToken
    /// account for the given amount of cash deposited, putting the nToken account at risk of liquidation.
    /// If the market is over leveraged, we call `deleverageMarket` to lend to the market instead.
    function _isMarketOverLeveraged(
        CashGroupParameters memory cashGroup,
        MarketParameters memory market,
        int256 leverageThreshold
    ) private pure returns (bool) {
        int256 totalCashUnderlying = cashGroup.primeRate.convertToUnderlying(market.totalPrimeCash);
        // Comparison we want to do:
        // (totalfCash) / (totalfCash + totalCashUnderlying) > leverageThreshold
        // However, the division will introduce rounding errors so we change this to:
        // totalfCash * RATE_PRECISION > leverageThreshold * (totalfCash + totalCashUnderlying)
        // Leverage threshold is denominated in rate precision.
        return (
            market.totalfCash.mul(Constants.RATE_PRECISION) >
            leverageThreshold.mul(market.totalfCash.add(totalCashUnderlying))
        );
    }

    function _addLiquidityToMarket(
        nTokenPortfolio memory nToken,
        MarketParameters memory market,
        uint256 index,
        int256 perMarketDeposit
    ) private returns (int256) {
        // Add liquidity to the market
        PortfolioAsset memory asset = nToken.portfolioState.storedAssets[index];
        // We expect that all the liquidity tokens are in the portfolio in order.
        require(
            asset.maturity == market.maturity &&
            // Ensures that the asset type references the proper liquidity token
            asset.assetType == index + Constants.MIN_LIQUIDITY_TOKEN_INDEX &&
            // Ensures that the storage state will not be overwritten
            asset.storageState == AssetStorageState.NoChange,
            "PT: invalid liquidity token"
        );

        // This will update the market state as well, fCashAmount returned here is negative
        (int256 liquidityTokens, int256 fCashAmount) = market.addLiquidity(perMarketDeposit);
        asset.notional = asset.notional.add(liquidityTokens);
        asset.storageState = AssetStorageState.Update;
        return fCashAmount;
    }

    /// @notice Lends into the market to reduce the leverage that the nToken will add liquidity at. May fail due
    /// to slippage or result in some amount of residual cash.
    function _deleverageMarket(
        CashGroupParameters memory cashGroup,
        MarketParameters memory market,
        int256 perMarketDeposit,
        uint256 blockTime,
        uint256 marketIndex,
        address tokenAddress
    ) private returns (int256, int256) {
        uint256 timeToMaturity = market.maturity.sub(blockTime);
        int256 fCashAmount;
        {
            // Shift the last implied rate by some buffer and calculate the exchange rate to fCash. Hope that this
            // is sufficient to cover all potential slippage. We don't use the `getfCashGivenCashAmount` method here
            // because it is very gas inefficient.
            int256 assumedExchangeRate;
            if (market.lastImpliedRate < Constants.DELEVERAGE_BUFFER) {
                // Floor the exchange rate at zero interest rate
                assumedExchangeRate = Constants.RATE_PRECISION;
            } else {
                assumedExchangeRate = InterestRateCurve.getfCashExchangeRate(
                    market.lastImpliedRate.sub(Constants.DELEVERAGE_BUFFER),
                    timeToMaturity
                );
            }

            int256 perMarketDepositUnderlying =
                cashGroup.primeRate.convertToUnderlying(perMarketDeposit);
            // NOTE: cash * exchangeRate = fCash
            fCashAmount = perMarketDepositUnderlying.mulInRatePrecision(assumedExchangeRate);
        }

        int256 netPrimeCash = market.executeTrade(
            tokenAddress, cashGroup, fCashAmount, timeToMaturity, marketIndex
        );

        // This means that the trade failed
        if (netPrimeCash == 0) {
            return (perMarketDeposit, 0);
        } else {
            // Ensure that net the per market deposit figure does not drop below zero, this should not be possible
            // given how we've calculated the exchange rate but extra caution here
            int256 residual = perMarketDeposit.add(netPrimeCash);
            require(residual >= 0); // dev: insufficient cash
            return (residual, fCashAmount);
        }
    }

    /// @notice If a nToken incurs a negative fCash residual as a result of lending, this means
    /// that we are going to need to withhold some amount of cash so that market makers can purchase and
    /// clear the debts off the balance sheet.
    function getNTokenNegativefCashWithholding(
        nTokenPortfolio memory nToken,
        MarketParameters[] memory previousMarkets,
        uint256 blockTime
    ) internal view returns (int256 totalCashWithholding) {
        bytes32 assetsBitmap = BitmapAssetsHandler.getAssetsBitmap(nToken.tokenAddress, nToken.cashGroup.currencyId);
        // This buffer is denominated in rate precision with 10 basis point increments. It is used to shift the
        // withholding rate to ensure that sufficient cash is withheld for negative fCash balances.
        uint256 oracleRateBuffer =
            uint256(uint8(nToken.parameters[Constants.CASH_WITHHOLDING_BUFFER])) * Constants.TEN_BASIS_POINTS;
        // If previousMarkets are supplied, then we are in initialize markets and we want to get the oracleRate
        // from the perspective of the previous tRef (represented by blockTime - QUARTER). The reason is that the
        // oracleRates for the current markets have not been set yet (we are in the process of calculating them
        // in this contract). In the other case, we are in sweepCashIntoMarkets and we can use the current block time.
        uint256 oracleRateBlockTime = previousMarkets.length == 0 ? blockTime : blockTime.sub(Constants.QUARTER);

        uint256 bitNum = assetsBitmap.getNextBitNum();
        while (bitNum != 0) {
            // lastInitializedTime is now the reference point for all ifCash bitmap
            uint256 maturity = DateTime.getMaturityFromBitNum(nToken.lastInitializedTime, bitNum);
            bool isValidMarket = DateTime.isValidMarketMaturity(
                nToken.cashGroup.maxMarketIndex,
                maturity,
                blockTime
            );

            // Only apply withholding for idiosyncratic fCash
            if (!isValidMarket) {
                int256 notional =
                    BitmapAssetsHandler.getifCashNotional(
                        nToken.tokenAddress,
                        nToken.cashGroup.currencyId,
                        maturity
                    );

                // Withholding only applies for negative cash balances
                if (notional < 0) {
                    // Oracle rates are calculated from the perspective of the previousMarkets during initialize
                    // markets here. It is possible that these oracle rates do not equal the oracle rates when we
                    // exit this method, this can happen if the nToken is above its leverage threshold. In that case
                    // this oracleRate will be higher than what we have when we exit, causing the nToken to withhold
                    // less cash than required. The NTOKEN_CASH_WITHHOLDING_BUFFER must be sufficient to cover this
                    // potential shortfall.
                    uint256 oracleRate = nToken.cashGroup.calculateOracleRate(maturity, oracleRateBlockTime);

                    if (oracleRateBuffer > oracleRate) {
                        oracleRate = 0;
                    } else {
                        oracleRate = oracleRate.sub(oracleRateBuffer);
                    }

                    totalCashWithholding = totalCashWithholding.sub(
                        AssetHandler.getPresentfCashValue(notional, maturity, blockTime, oracleRate)
                    );
                }
            }

            // Turn off the bit and look for the next one
            assetsBitmap = assetsBitmap.setBit(bitNum, false);
            bitNum = assetsBitmap.getNextBitNum();
        }

        return nToken.cashGroup.primeRate.convertFromUnderlying(totalCashWithholding);
    }
}
