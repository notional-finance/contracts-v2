// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    PrimeRate,
    PortfolioState,
    MarketParameters,
    BalanceState,
    CashGroupParameters,
    nTokenPortfolio,
    InterestRateParameters,
    PortfolioAsset
} from "../../global/Types.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {Bitmap} from "../../math/Bitmap.sol";

import {Emitter} from "../../internal/Emitter.sol";
import {Market} from "../../internal/markets/Market.sol";
import {DateTime} from "../../internal/markets/DateTime.sol";
import {CashGroup} from "../../internal/markets/CashGroup.sol";
import {InterestRateCurve} from "../../internal/markets/InterestRateCurve.sol";
import {PrimeRateLib} from "../../internal/pCash/PrimeRateLib.sol";
import {BalanceHandler} from "../../internal/balances/BalanceHandler.sol";
import {PortfolioHandler} from "../../internal/portfolio/PortfolioHandler.sol";
import {BitmapAssetsHandler} from "../../internal/portfolio/BitmapAssetsHandler.sol";
import {SettleBitmapAssets} from "../../internal/settlement/SettleBitmapAssets.sol";
import {nTokenHandler} from "../../internal/nToken/nTokenHandler.sol";
import {AssetHandler} from "../../internal/valuation/AssetHandler.sol";

import {nTokenMintAction} from "./nTokenMintAction.sol";

/// @notice Initialize markets is called once every quarter to setup the new markets. Only the nToken account
/// can initialize markets, and this method will be called on behalf of that account. In this action
/// the following will occur:
///  - nToken Liquidity Tokens will be settled
///  - Any ifCash assets will be settled
///  - If nToken liquidity tokens are settled with negative net ifCash, enough cash will be withheld at the PV
///    to purchase offsetting positions
///  - fCash positions are written to storage
///  - For each market, calculate the proportion of fCash to cash given:
///     - previous oracle rates
///     - rate anchor set by governance
///     - percent of cash to deposit into the market set by governance
///  - Set new markets and add liquidity tokens to portfolio
library InitializeMarketsAction {
    using Bitmap for bytes32;
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using PortfolioHandler for PortfolioState;
    using Market for MarketParameters;
    using BalanceHandler for BalanceState;
    using CashGroup for CashGroupParameters;
    using PrimeRateLib for PrimeRate;
    using nTokenHandler for nTokenPortfolio;
    using InterestRateCurve for InterestRateParameters;

    event MarketsInitialized(uint16 currencyId);

    struct GovernanceParameters {
        int256[] depositShares;
        int256[] leverageThresholds;
        uint256[] proportions;
        InterestRateParameters[] interestRateParams;
    }

    function _getGovernanceParameters(uint16 currencyId, uint256 maxMarketIndex)
        private
        returns (GovernanceParameters memory)
    {
        GovernanceParameters memory params;
        (params.depositShares, params.leverageThresholds) = nTokenHandler.getDepositParameters(
            currencyId,
            maxMarketIndex
        );

        int256[] memory _proportions = nTokenHandler.getInitializationParameters(currencyId, maxMarketIndex);
        // NOTE: this conversion from int256 => uint256 is done for legacy reasons
        params.proportions = new uint256[](_proportions.length);
        for (uint256 i = 0; i < _proportions.length; i++) {
            params.proportions[i] = _proportions[i].toUint();
        }

        // Copies the next interest rate parameters set by governance into the
        // "active" interest rate parameters for the current quarter.
        InterestRateCurve.setActiveInterestRateParameters(currencyId);
        params.interestRateParams = new InterestRateParameters[](maxMarketIndex);
        // maxMarketIndex is 1-indexed
        for (uint256 i = 1; i <= maxMarketIndex; i++) {
            params.interestRateParams[i - 1] = InterestRateCurve.getActiveInterestRateParameters(
            currencyId,
                i
        );
        }

        return params;
    }

    function _settleNTokenPortfolio(nTokenPortfolio memory nToken, uint256 blockTime) private {
        // nToken never has idiosyncratic cash between 90 day intervals but since it also has a
        // bitmap fCash assets. We don't set the pointer to the settlement date of the liquidity
        // tokens (1 quarter away), instead we set it to the current block time. This is a bit
        // esoteric but will ensure that ifCash is never improperly settled.

        // If lastInitializedTime == reference time then this will fail, that is the correct
        // behavior since initialization begins at lastInitializedTime. That means that markets
        // cannot be re-initialized during a single block (this is the correct behavior). If
        // lastInitializedTime >= reference time then the markets have already been initialized
        // for the quarter.
        uint256 referenceTime = DateTime.getReferenceTime(blockTime);
        require(nToken.lastInitializedTime < referenceTime, "IM: invalid time");

        {
            // Settles liquidity token balances and portfolio state now contains the net fCash amounts
            SettleAmount[] memory settleAmount =
                SettlePortfolioAssets.settlePortfolio(nToken.portfolioState, blockTime);
            nToken.cashBalance = nToken.cashBalance.add(settleAmount[0].netCashChange);
        }

        (int256 settledPrimeCash, uint256 blockTimeUTC0) =
            SettleBitmapAssets.settleBitmappedCashGroup(
                nToken.tokenAddress,
                nToken.cashGroup.currencyId,
                nToken.lastInitializedTime,
                blockTime
            );
        nToken.cashBalance = nToken.cashBalance.add(settledPrimeCash);

        // The ifCashBitmap has been updated to reference this new settlement time
        require(blockTimeUTC0 <= type(uint40).max);
        nToken.lastInitializedTime = uint40(blockTimeUTC0);
    }

    /// @notice Special method to get previous markets, normal usage would not reference previous markets
    /// in this way
    function _getPreviousMarkets(
        uint256 currencyId,
        uint256 blockTime,
        nTokenPortfolio memory nToken,
        MarketParameters[] memory previousMarkets
    ) private view {
        uint256 rateOracleTimeWindow = nToken.cashGroup.getRateOracleTimeWindow();
        // This will reference the previous settlement date to get the previous markets
        uint256 settlementDate = DateTime.getReferenceTime(blockTime);

        // Assume that assets are stored in order and include all assets of the previous market
        // set. This will account for the potential that markets.length is greater than the previous
        // markets when the maxMarketIndex is increased (increasing the overall number of markets).
        // We don't fetch the 3 month market (i = 0) because it has settled and will not be used for
        // the subsequent calculations. Since nTokens never allow liquidity to go to zero then we know
        // there is always a matching token for each market.
        for (uint256 i = 1; i < nToken.portfolioState.storedAssets.length; i++) {
            previousMarkets[i].loadMarketWithSettlementDate(
                currencyId,
                // These assets will reference the previous liquidity tokens
                nToken.portfolioState.storedAssets[i].maturity,
                blockTime,
                // No liquidity tokens required for this process
                false,
                rateOracleTimeWindow,
                settlementDate
            );
        }
    }

    /// @notice Check the net fCash assets set by the portfolio and withhold cash to account for
    /// the PV of negative ifCash. Also sets the ifCash assets into the nToken mapping.
    function _withholdAndSetfCashAssets(
        nTokenPortfolio memory nToken,
        MarketParameters[] memory previousMarkets,
        uint256 currencyId,
        uint256 blockTime
    ) private returns (int256) {
        // Residual fcash must be put into the ifCash bitmap from the portfolio, skip the 3 month
        // liquidity token since there is no residual fCash for that maturity, it always settles to cash.
        for (uint256 i = 1; i < nToken.portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = nToken.portfolioState.storedAssets[i];
            // Defensive check to ensure that everything is an fcash asset, all liquidity tokens after
            // the three month should have been settled to fCash at this point.
            require(asset.assetType == Constants.FCASH_ASSET_TYPE);

            BitmapAssetsHandler.addifCashAsset(
                nToken.tokenAddress,
                currencyId,
                asset.maturity,
                nToken.lastInitializedTime,
                asset.notional
            );

            // Do not have fCash assets stored in the portfolio
            nToken.portfolioState.deleteAsset(i);
        }

        // Recalculate what the withholdings are if there are any ifCash assets remaining
        return _getNTokenNegativefCashWithholding(nToken, previousMarkets, blockTime);
    }

    /// @notice If a nToken incurs a negative fCash residual as a result of lending, this means
    /// that we are going to need to withhold some amount of cash so that market makers can purchase and
    /// clear the debts off the balance sheet.
    function _getNTokenNegativefCashWithholding(
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

        return nToken.cashGroup.assetRate.convertFromUnderlying(totalCashWithholding);
    }

    function _calculateNetPrimeCashAvailable(
        nTokenPortfolio memory nToken,
        MarketParameters[] memory previousMarkets,
        uint256 blockTime,
        uint256 currencyId,
        bool isFirstInit
    ) private returns (int256 netPrimeCashAvailable) {
        int256 primeCashWithholding;

        if (isFirstInit) {
            nToken.lastInitializedTime = uint40(DateTime.getTimeUTC0(blockTime));
        } else {
            _settleNTokenPortfolio(nToken, blockTime);
            _getPreviousMarkets(currencyId, blockTime, nToken, previousMarkets);
            primeCashWithholding = _withholdAndSetfCashAssets(
                nToken,
                previousMarkets,
                currencyId,
                blockTime
            );
        }

        // Deduct the amount of withholding required from the cash balance (at this point includes all settled cash)
        netPrimeCashAvailable = nToken.cashBalance.subNoNeg(primeCashWithholding);

        // This is the new balance to store
        nToken.cashBalance = primeCashWithholding;

        // We can't have less net asset cash than our percent basis or some markets will end up not
        // initialized
        require(
            netPrimeCashAvailable > int256(Constants.DEPOSIT_PERCENT_BASIS),
            "IM: insufficient cash"
        );

        return netPrimeCashAvailable;
    }

    /// @notice The six month implied rate is zero if there have never been any markets initialized
    /// otherwise the market will be the interpolation between the old 6 month and 1 year markets
    /// which are now sitting at 3 month and 9 month time to maturity
    function _getSixMonthImpliedRate(
        MarketParameters[] memory previousMarkets,
        uint256 referenceTime
    ) private pure returns (uint256) {
        // Cannot interpolate six month rate without a 1 year market
        require(previousMarkets.length >= 3);

        return
            CashGroup.interpolateOracleRate(
                previousMarkets[1].maturity,
                previousMarkets[2].maturity,
                previousMarkets[1].oracleRate,
                previousMarkets[2].oracleRate,
                // Maturity date == 6 months from reference time
                referenceTime + 2 * Constants.QUARTER
            );
    }

    /// @notice Returns the linear interpolation between two market rates. The formula is
    /// slope = (longMarket.oracleRate - shortMarket.oracleRate) / (longMarket.maturity - shortMarket.maturity)
    /// interpolatedRate = slope * (assetMaturity - shortMarket.maturity) + shortMarket.oracleRate
    function _interpolateFutureRate(
        uint256 shortMaturity,
        uint256 shortRate,
        MarketParameters memory longMarket
    ) private pure returns (uint256) {
        uint256 longMaturity = longMarket.maturity;
        uint256 longRate = longMarket.oracleRate;
        // the next market maturity is always a quarter away
        uint256 newMaturity = longMarket.maturity + Constants.QUARTER;
        require(shortMaturity < longMaturity);

        // It's possible that the rates are inverted where the short market rate > long market rate and
        // we will get an underflow here so we check for that
        if (longRate >= shortRate) {
            return
                (longRate - shortRate)
                    .mul(newMaturity - shortMaturity)
                // No underflow here, checked above
                    .div(longMaturity - shortMaturity)
                    .add(shortRate);
        } else {
            // In this case the slope is negative so:
            // interpolatedRate = shortMarket.oracleRate - slope * (assetMaturity - shortMarket.maturity)
            uint256 diff =
                (shortRate - longRate)
                    .mul(newMaturity - shortMaturity)
                // No underflow here, checked above
                    .div(longMaturity - shortMaturity);

            // This interpolation may go below zero so we bottom out interpolated rates at (practically)
            // zero. Storing a zero for oracleRates means that the markets are not initialized so using
            // a minimum value here to handle that case
            return shortRate > diff ? shortRate - diff : 1;
        }
    }

    /// @dev This is here to clear the stack
    function _setLiquidityAmount(
        int256 netPrimeCashAvailable,
        int256 depositShare,
        uint256 assetType,
        MarketParameters memory newMarket,
        nTokenPortfolio memory nToken
    ) private pure returns (int256) {
        // The portion of the cash available that will be deposited into the market
        int256 primeCashToMarket =
            netPrimeCashAvailable.mul(depositShare).div(Constants.DEPOSIT_PERCENT_BASIS);
        newMarket.totalPrimeCash = primeCashToMarket;
        newMarket.totalLiquidity = primeCashToMarket;

        // Add a new liquidity token, this will end up in the new asset array
        nToken.portfolioState.addAsset(
            nToken.cashGroup.currencyId,
            newMarket.maturity,
            assetType, // This is liquidity token asset type
            primeCashToMarket
        );

        // fCashAmount is calculated using the underlying amount
        return nToken.cashGroup.assetRate.convertToUnderlying(primeCashToMarket);
    }

    /// @notice Calculates the fCash amount given the cash and utilization:
    // utilization = totalfCash / (totalfCash + totalCashUnderlying)
    // utilization * (totalfCash + totalCashUnderlying) = totalfCash
    // utilization * totalCashUnderlying + utilization * totalfCash = totalfCash
    // utilization * totalCashUnderlying = totalfCash * (1 - utilization)
    // totalfCash = utilization * totalCashUnderlying / (1 - utilization)
    function _calculatefCashAmountFromUtilization(
        int256 underlyingCashToMarket,
        uint256 utilization 
    ) private pure returns (int256) {
        require(utilization < uint256(Constants.RATE_PRECISION));
        int256 _utilization = int256(utilization);
        // NOTE: sub underflow checked above, no div by zero possible
        return (underlyingCashToMarket.mul(_utilization) / (Constants.RATE_PRECISION - _utilization));
    }

    /// @notice Sweeps nToken cash balance into markets after accounting for cash withholding. Can be
    /// done after fCash residuals are purchased to ensure that markets have maximum liquidity.
    /// @param currencyId currency of markets to initialize
    /// @dev emit:CashSweepIntoMarkets
    /// @dev auth:none
    function sweepCashIntoMarkets(uint16 currencyId) external {
        uint256 blockTime = block.timestamp;
        nTokenPortfolio memory nToken;
        nToken.loadNTokenPortfolioStateful(currencyId);
        require(nToken.portfolioState.storedAssets.length > 0, "No nToken assets");

        // Can only sweep cash after markets have been initialized
        uint256 referenceTime = DateTime.getReferenceTime(blockTime);
        require(nToken.lastInitializedTime >= referenceTime, "Must initialize markets");

        // Can only sweep cash after the residual purchase time has passed
        uint256 minSweepCashTime =
            nToken.lastInitializedTime.add(
                uint256(uint8(nToken.parameters[Constants.RESIDUAL_PURCHASE_TIME_BUFFER])) * 1 hours
            );
        require(blockTime > minSweepCashTime, "Invalid sweep cash time");

        int256 primeCashWithholding =
            _getNTokenNegativefCashWithholding(
                nToken,
                new MarketParameters[](0), // Parameter is unused when referencing current markets
                blockTime
            );

        int256 cashIntoMarkets = nToken.cashBalance.subNoNeg(primeCashWithholding);
        BalanceHandler.setBalanceStorageForNToken(
            nToken.tokenAddress,
            nToken.cashGroup.currencyId,
            primeCashWithholding
        );

        // This will deposit the cash balance into markets, but will not record a token supply change.
        nTokenMintAction.nTokenMint(currencyId, cashIntoMarkets);
        emit SweepCashIntoMarkets(currencyId, cashIntoMarkets);
    }

    /// @notice Initialize the market for a given currency id, done once a quarter
    /// @param currencyId currency of markets to initialize
    /// @param isFirstInit true if this is the first time the markets have been initialized
    /// @dev emit:MarketsInitialized
    /// @dev auth:none
    function initializeMarkets(uint16 currencyId, bool isFirstInit) external {
        uint256 blockTime = block.timestamp;
        nTokenPortfolio memory nToken;
        nToken.loadNTokenPortfolioStateful(currencyId);
        MarketParameters[] memory previousMarkets =
            new MarketParameters[](nToken.cashGroup.maxMarketIndex);

        // This should be sufficient to validate that the currency id is valid
        require(nToken.cashGroup.maxMarketIndex != 0);
        // If the nToken has any assets then this is not the first initialization
        if (isFirstInit) {
            require(nToken.portfolioState.storedAssets.length == 0);
        }

        int256 netPrimeCashAvailable = _calculateNetPrimeCashAvailable(
            nToken,
            previousMarkets,
            blockTime,
            currencyId,
            isFirstInit
        );

        GovernanceParameters memory parameters =
            _getGovernanceParameters(currencyId, nToken.cashGroup.maxMarketIndex);

        MarketParameters memory newMarket;
        // Oracle rate is carried over between loops
        uint256 oracleRate;
        for (uint256 i = 0; i < nToken.cashGroup.maxMarketIndex; i++) {
            // Traded markets are 1-indexed
            newMarket.maturity = DateTime.getReferenceTime(blockTime).add(
                DateTime.getTradedMarket(i + 1)
            );

            int256 underlyingCashToMarket =
                _setLiquidityAmount(
                    netPrimeCashAvailable,
                    parameters.depositShares[i],
                    Constants.MIN_LIQUIDITY_TOKEN_INDEX + i, // liquidity token asset type
                    newMarket,
                    nToken
                );

            // Governance will prevent previousMarkets.length from being equal to 1, meaning that we will
            // either have 0 markets (on first init), exactly 2 markets, or 2+ markets. In the case that there
            // are exactly two markets then the 6 month market must be initialized via this method (there is no
            // 9 month market to interpolate a rate against). In the case of 2+ markets then we will only enter this
            // first branch when the number of markets is increased
            if (
                isFirstInit ||
                // This is the six month market when there are only 3 and 6 month markets
                (i == 1 && previousMarkets.length == 2) ||
                // At this point, these are new markets and they must be initialized
                (i >= nToken.portfolioState.storedAssets.length) ||
                // When extending from the 6 month to 1 year market we must initialize both 6 and 1 year as new
                (i == 1 && previousMarkets[2].oracleRate == 0)
            ) {
                // Any newly added markets cannot have their implied rates interpolated via the previous
                // markets. In this case we initialize the markets using the rate anchor and proportion.
                int256 fCashAmount = _calculatefCashAmountFromUtilization(underlyingCashToMarket, parameters.proportions[i]);

                newMarket.totalfCash = fCashAmount;
                newMarket.oracleRate = parameters.interestRateParams[i].getInterestRate(parameters.proportions[i]);

                // If this fails it is because the rate anchor and proportion are not set properly by
                // governance.
                require(newMarket.oracleRate > 0, "IM: implied rate failed");
            } else {
                // Two special cases for the 3 month and 6 month market when interpolating implied rates. The 3 month market
                // inherits the implied rate from the previous 6 month market (they are now at the same maturity).
                if (i == 0) {
                    // We should never get an array out of bounds error here because of the inequality check in the first branch
                    // of the outer if statement.
                    oracleRate = previousMarkets[1].oracleRate;
                } else if (i == 1) {
                    // The six month market is the interpolation between the 3 month and the 1 year market (now at 9 months). This
                    // interpolation is different since the rate is between 3 and 9 months, for all the other interpolations we interpolate
                    // forward in time (i.e. use a 3 and 6 month rate to interpolate a 1 year rate). The first branch of this if statement
                    // will capture the case when the 1 year rate has not been set.
                    oracleRate = _getSixMonthImpliedRate(
                        previousMarkets,
                        DateTime.getReferenceTime(blockTime)
                    );
                } else {
                    // Any other market has the interpolation between the new implied rate from the newly initialized market previous
                    // to this market interpolated with the previous version of this market. For example, the newly initialized 1 year
                    // market will have its implied rate set to the interpolation between the newly initialized 6 month market (done in
                    // previous iteration of this loop) and the previous 1 year market (which has now rolled down to 9 months). Similarly,
                    // a 2 year market will be interpolated from the newly initialized 1 year and the previous 2 year market.

                    // This is the previous market maturity, traded markets are 1-indexed
                    uint256 shortMarketMaturity =
                        DateTime.getReferenceTime(blockTime).add(DateTime.getTradedMarket(i));
                    oracleRate = _interpolateFutureRate(
                        shortMarketMaturity,
                        // This is the oracle rate from the previous iteration in the loop,
                        // refers to the new oracle rate set on the newly initialized market
                        // that is adjacent to the market currently being initialized.
                        oracleRate,
                        // This is the previous version of the current market
                        previousMarkets[i]
                    );
                }

                // When initializing new markets we need to ensure that the new implied oracle rates align
                // with the current yield curve or valuations for ifCash will spike. This should reference the
                // previously calculated implied rate and the current market.
                uint256 utilization = parameters.interestRateParams[i].getUtilizationFromInterestRate(oracleRate);

                // If the calculated utilization is greater than the leverage threshold then we cannot
                // provide liquidity without risk of liquidation. In this case, set the leverage threshold
                // as the new utilization and calculate the oracle rate from it. This will result in fCash valuations
                // changing on chain, however, adding liquidity via nTokens would also end up with this
                // result as well.
                if (utilization > parameters.leverageThresholds[i].toUint()) {
                    utilization = parameters.leverageThresholds[i].toUint();
                    oracleRate = parameters.interestRateParams[i].getInterestRate(utilization);
                    require(oracleRate != 0, "Oracle rate overflow");
                }

                newMarket.totalfCash = _calculatefCashAmountFromUtilization(underlyingCashToMarket, utilization);

                // It's possible that totalfCash is zero from rounding errors above, we want to set this to a minimum value
                // so that we don't have divide by zero errors.
                if (newMarket.totalfCash < 1) newMarket.totalfCash = 1;

                newMarket.oracleRate = oracleRate;
                // The oracle rate has been changed so we set the previous trade time to current
                newMarket.previousTradeTime = blockTime;
            }

            // Implied rate will always be set to oracle rate
            newMarket.lastImpliedRate = newMarket.oracleRate;
            finalizeMarket(newMarket, currencyId, nToken);
        }

        // prettier-ignore
        (
            /* hasDebt */,
            /* activeCurrencies */,
            uint8 assetArrayLength,
            /* nextSettleTime */
        ) = nToken.portfolioState.storeAssets(nToken.tokenAddress);
        BalanceHandler.setBalanceStorageForNToken(
            nToken.tokenAddress,
            currencyId,
            nToken.cashBalance
        );
        nTokenHandler.setArrayLengthAndInitializedTime(
            nToken.tokenAddress,
            assetArrayLength,
            nToken.lastInitializedTime
        );

        emit MarketsInitialized(uint16(currencyId));
    }

    function finalizeMarket(
        MarketParameters memory market,
        uint16 currencyId,
        nTokenPortfolio memory nToken
    ) internal {
        // Always reference the current settlement date
        uint256 settlementDate = DateTime.getReferenceTime(block.timestamp) + Constants.QUARTER;
        market.setMarketStorageForInitialize(currencyId, settlementDate);

        BitmapAssetsHandler.addifCashAsset(
            nToken.tokenAddress,
            currencyId,
            market.maturity,
            nToken.lastInitializedTime,
            market.totalfCash.neg()
        );
    }

    /// @notice Get a list of deployed library addresses (sorted by library name)
    function getLibInfo() external pure returns (address) {
        return address(nTokenMintAction);
    }
}
