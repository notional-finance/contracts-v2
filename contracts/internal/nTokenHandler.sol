// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../global/LibStorage.sol";
import "./markets/CashGroup.sol";
import "./markets/AssetRate.sol";
import "./valuation/AssetHandler.sol";
import "./portfolio/BitmapAssetsHandler.sol";
import "./portfolio/PortfolioHandler.sol";
import "./balances/BalanceHandler.sol";
import "../math/SafeInt256.sol";
import "../math/Bitmap.sol";

library nTokenHandler {
    using AssetRate for AssetRateParameters;
    using SafeInt256 for int256;
    using Bitmap for bytes32;
    using CashGroup for CashGroupParameters;

    /// @dev Mirror of the value in LibStorage
    uint256 private constant NUM_NTOKEN_MARKET_FACTORS = 14;

    /// @notice Returns an account context object that is specific to nTokens.
    function getNTokenContext(address tokenAddress)
        internal
        view
        returns (
            uint16 currencyId,
            uint256 incentiveAnnualEmissionRate,
            uint256 lastInitializedTime,
            uint8 assetArrayLength,
            bytes5 parameters
        )
    {
        mapping(address => nTokenContext) storage store = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = store[tokenAddress];

        // TODO: how many storage reads is this?
        currencyId = context.currencyId;
        incentiveAnnualEmissionRate = context.incentiveAnnualEmissionRate;
        lastInitializedTime = context.lastInitializedTime;
        assetArrayLength = context.assetArrayLength;
        parameters = context.nTokenParameters;
    }

    /// @notice Returns the nToken token address for a given currency
    function nTokenAddress(uint256 currencyId) internal view returns (address tokenAddress) {
        mapping(uint256 => address) storage store = LibStorage.getNTokenAddressStorage();
        return store[currencyId];
    }

    /// @notice Called by governance to set the nToken token address and its reverse lookup. Cannot be
    /// reset once this is set.
    function setNTokenAddress(uint16 currencyId, address tokenAddress) internal {
        mapping(uint256 => address) storage addressStore = LibStorage.getNTokenAddressStorage();
        require(addressStore[currencyId] == address(0), "PT: token address exists");

        mapping(address => nTokenContext) storage contextStore = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = contextStore[tokenAddress];
        require(context.currencyId == 0, "PT: currency exists");

        // This will initialize all other context slots to zero
        context.currencyId = currencyId;
        addressStore[currencyId] = tokenAddress;
    }

    /// @notice Set nToken token collateral parameters
    function setNTokenCollateralParameters(
        address tokenAddress,
        uint8 residualPurchaseIncentive10BPS,
        uint8 pvHaircutPercentage,
        uint8 residualPurchaseTimeBufferHours,
        uint8 cashWithholdingBuffer10BPS,
        uint8 liquidationHaircutPercentage
    ) internal {
        mapping(address => nTokenContext) storage store = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = store[tokenAddress];

        require(liquidationHaircutPercentage <= Constants.PERCENTAGE_DECIMALS, "Invalid haircut");
        // The pv haircut percentage must be less than the liquidation percentage or else liquidators will not
        // get profit for liquidating nToken.
        require(pvHaircutPercentage < liquidationHaircutPercentage, "Invalid pv haircut");
        // Ensure that the cash withholding buffer is greater than the residual purchase incentive or
        // the nToken may not have enough cash to pay accounts to buy its negative ifCash
        require(residualPurchaseIncentive10BPS <= cashWithholdingBuffer10BPS, "Invalid discounts");

        bytes5 parameters =
            (bytes5(uint40(residualPurchaseIncentive10BPS)) |
            (bytes5(uint40(pvHaircutPercentage)) << 8) |
            (bytes5(uint40(residualPurchaseTimeBufferHours)) << 16) |
            (bytes5(uint40(cashWithholdingBuffer10BPS)) << 24) |
            (bytes5(uint40(liquidationHaircutPercentage)) << 32));

        // Set the parameters
        context.nTokenParameters = parameters;
    }

    /// @notice Retrieves the nToken supply factors without any updates or calculations
    function getStoredNTokenSupplyFactors(address tokenAddress)
        internal
        view
        returns (
            uint256 totalSupply,
            uint256 integralTotalSupply,
            uint256 lastSupplyChangeTime
        )
    {
        mapping(address => nTokenTotalSupplyStorage) storage store = LibStorage.getNTokenTotalSupplyStorage();
        nTokenTotalSupplyStorage storage nTokenStorage = store[tokenAddress];
        totalSupply = nTokenStorage.totalSupply;
        // NOTE: DO NOT USE THIS RETURNED VALUE FOR CALCULATING INCENTIVES. The integral total supply
        // must be updated given the block time. Use `calculateIntegralTotalSupply` instead
        integralTotalSupply = nTokenStorage.integralTotalSupply;
        lastSupplyChangeTime = nTokenStorage.lastSupplyChangeTime;
    }

    /// @notice Retrieves stored total supply factors and 
    function calculateIntegralTotalSupply(address tokenAddress, uint256 blockTime) 
        internal
        view 
        returns (
            uint256 totalSupply,
            uint256 integralTotalSupply,
            uint256 lastSupplyChangeTime
        )
    {
        (
            totalSupply,
            integralTotalSupply,
            lastSupplyChangeTime
        ) = getStoredNTokenSupplyFactors(tokenAddress);

        // Initialize last supply change time if it has not been set.
        if (lastSupplyChangeTime == 0) lastSupplyChangeTime = blockTime;

        require(blockTime >= lastSupplyChangeTime); // dev: invalid block time

        // Add to the integral total supply the total supply of tokens multiplied by the time that the total supply
        // has been the value. This will part of the numerator for the average total supply calculation during
        // minting incentives.
        integralTotalSupply = uint256(int256(integralTotalSupply).add(
            int256(totalSupply).mul(int256(blockTime - lastSupplyChangeTime))
        ));

        require(integralTotalSupply >= 0 && integralTotalSupply < type(uint128).max); // dev: integral total supply overflow
        require(blockTime < type(uint32).max); // dev: last supply change supply overflow
    }


    /// @notice Updates the nToken token supply amount when minting or redeeming.
    function changeNTokenSupply(
        address tokenAddress,
        int256 netChange,
        uint256 blockTime
    ) internal returns (uint256) {
        (
            uint256 totalSupply,
            uint256 integralTotalSupply,
            /* uint256 lastSupplyChangeTime */
        ) = calculateIntegralTotalSupply(tokenAddress, blockTime);

        if (netChange != 0) {
            // If the totalSupply will change then we store the new total supply, the integral total supply and the
            // current block time. We know that this int256 conversion will not overflow because totalSupply is stored
            // as a uint96 and checked in the next line.
            int256 newTotalSupply = int256(totalSupply).add(netChange);
            require(newTotalSupply >= 0 && uint256(newTotalSupply) < type(uint96).max); // dev: nToken supply overflow

            mapping(address => nTokenTotalSupplyStorage) storage store = LibStorage.getNTokenTotalSupplyStorage();
            nTokenTotalSupplyStorage storage nTokenStorage = store[tokenAddress];

            nTokenStorage.totalSupply = uint96(newTotalSupply);
            // NOTE: overflows checked in calculateIntegralTotalSupply
            nTokenStorage.integralTotalSupply = uint128(integralTotalSupply);
            nTokenStorage.lastSupplyChangeTime = uint32(blockTime);
        }

        return integralTotalSupply;
    }

    function setIncentiveEmissionRate(address tokenAddress, uint32 newEmissionsRate) internal {
        mapping(address => nTokenContext) storage store = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = store[tokenAddress];
        context.incentiveAnnualEmissionRate = newEmissionsRate;
    }

    function setArrayLengthAndInitializedTime(
        address tokenAddress,
        uint8 arrayLength,
        uint256 lastInitializedTime
    ) internal {
        require(lastInitializedTime >= 0 && uint256(lastInitializedTime) < type(uint32).max); // dev: next settle time overflow
        mapping(address => nTokenContext) storage store = LibStorage.getNTokenContextStorage();
        nTokenContext storage context = store[tokenAddress];
        context.lastInitializedTime = uint32(lastInitializedTime);
        context.assetArrayLength = arrayLength;
    }

    /// @notice Returns the array of deposit shares and leverage thresholds for nTokens
    function getDepositParameters(uint256 currencyId, uint256 maxMarketIndex)
        internal
        view
        returns (int256[] memory depositShares, int256[] memory leverageThresholds)
    {
        mapping(uint256 => uint32[NUM_NTOKEN_MARKET_FACTORS]) storage store = LibStorage.getNTokenDepositStorage();
        uint32[NUM_NTOKEN_MARKET_FACTORS] storage depositParameters = store[currencyId];
        (depositShares, leverageThresholds) = _getParameters(depositParameters, maxMarketIndex, false);
    }

    /// @notice Sets the deposit parameters
    /// @dev We pack the values in alternating between the two parameters into either one or two
    // storage slots depending on the number of markets. This is to save storage reads when we use the parameters.
    function setDepositParameters(
        uint256 currencyId,
        uint32[] calldata depositShares,
        uint32[] calldata leverageThresholds
    ) internal {
        require(
            depositShares.length <= Constants.MAX_TRADED_MARKET_INDEX,
            "PT: deposit share length"
        );
        require(depositShares.length == leverageThresholds.length, "PT: leverage share length");

        uint256 shareSum;
        for (uint256 i; i < depositShares.length; i++) {
            // This cannot overflow in uint 256 with 9 max slots
            shareSum = shareSum + depositShares[i];
            require(
                leverageThresholds[i] > 0 && leverageThresholds[i] < Constants.RATE_PRECISION,
                "PT: leverage threshold"
            );
        }

        // Total deposit share must add up to 100%
        require(shareSum == uint256(Constants.DEPOSIT_PERCENT_BASIS), "PT: deposit shares sum");

        mapping(uint256 => uint32[NUM_NTOKEN_MARKET_FACTORS]) storage store = LibStorage.getNTokenDepositStorage();
        uint32[NUM_NTOKEN_MARKET_FACTORS] storage depositParameters = store[currencyId];
        _setParameters(depositParameters, depositShares, leverageThresholds);
    }

    /// @notice Sets the initialization parameters for the markets, these are read only when markets
    /// are initialized
    function setInitializationParameters(
        uint256 currencyId,
        uint32[] calldata annualizedAnchorRates,
        uint32[] calldata proportions
    ) internal {
        require(annualizedAnchorRates.length <= Constants.MAX_TRADED_MARKET_INDEX, "PT: annualized anchor rates length");
        require(proportions.length == annualizedAnchorRates.length, "PT: proportions length");

        for (uint256 i; i < proportions.length; i++) {
            // Proportions must be between zero and the rate precision
            require(annualizedAnchorRates[i] > 0, "NT: anchor rate zero");
            require(
                proportions[i] > 0 && proportions[i] < Constants.RATE_PRECISION,
                "PT: invalid proportion"
            );
        }

        mapping(uint256 => uint32[NUM_NTOKEN_MARKET_FACTORS]) storage store = LibStorage.getNTokenInitStorage();
        uint32[NUM_NTOKEN_MARKET_FACTORS] storage initParameters = store[currencyId];
        _setParameters(initParameters, annualizedAnchorRates, proportions);
    }

    /// @notice Returns the array of initialization parameters for a given currency.
    function getInitializationParameters(uint256 currencyId, uint256 maxMarketIndex)
        internal
        view
        returns (int256[] memory annualizedAnchorRates, int256[] memory proportions)
    {
        mapping(uint256 => uint32[NUM_NTOKEN_MARKET_FACTORS]) storage store = LibStorage.getNTokenInitStorage();
        uint32[NUM_NTOKEN_MARKET_FACTORS] storage initParameters = store[currencyId];
        (annualizedAnchorRates, proportions) = _getParameters(initParameters, maxMarketIndex, true);
    }

    function _getParameters(
        uint32[NUM_NTOKEN_MARKET_FACTORS] storage slot,
        uint256 maxMarketIndex,
        bool noUnset
    ) private view returns (int256[] memory, int256[] memory) {
        uint256 index = 0;
        int256[] memory array1 = new int256[](maxMarketIndex);
        int256[] memory array2 = new int256[](maxMarketIndex);
        for (uint256 i; i < maxMarketIndex; i++) {
            array1[i] = slot[index];
            index++;
            array2[i] = slot[index];
            index++;

            if (noUnset) {
                require(array1[i] > 0 && array2[i] > 0, "PT: init value zero");
            }
        }

        return (array1, array2);
    }

    function _setParameters(
        uint32[NUM_NTOKEN_MARKET_FACTORS] storage slot,
        uint32[] calldata array1,
        uint32[] calldata array2
    ) private {
        uint256 index = 0;
        for (uint256 i = 0; i < array1.length; i++) {
            slot[index] = array1[i];
            index++;

            slot[index] = array2[i];
            index++;
        }
    }

    function loadNTokenPortfolioNoCashGroup(nTokenPortfolio memory nToken, uint16 currencyId)
        internal
        view
    {
        nToken.tokenAddress = nTokenAddress(currencyId);
        // prettier-ignore
        (
            /* currencyId */,
            /* incentiveRate */,
            uint256 lastInitializedTime,
            uint8 assetArrayLength,
            bytes5 parameters
        ) = getNTokenContext(nToken.tokenAddress);

        // prettier-ignore
        (
            uint256 totalSupply,
            /* integralTotalSupply */,
            /* lastSupplyChangeTime */
        ) = getStoredNTokenSupplyFactors(nToken.tokenAddress);

        nToken.lastInitializedTime = lastInitializedTime;
        nToken.totalSupply = int256(totalSupply);
        nToken.parameters = parameters;

        nToken.portfolioState = PortfolioHandler.buildPortfolioState(
            nToken.tokenAddress,
            assetArrayLength,
            0
        );

        // prettier-ignore
        (
            nToken.cashBalance,
            /* nTokenBalance */,
            /* lastClaimTime */,
            /* lastClaimIntegralSupply */
        ) = BalanceHandler.getBalanceStorage(nToken.tokenAddress, currencyId);
    }

    /// @notice Uses buildCashGroupStateful
    function loadNTokenPortfolioStateful(nTokenPortfolio memory nToken, uint16 currencyId)
        internal
    {
        loadNTokenPortfolioNoCashGroup(nToken, currencyId);
        nToken.cashGroup = CashGroup.buildCashGroupStateful(currencyId);
    }

    /// @notice Uses buildCashGroupView
    function loadNTokenPortfolioView(nTokenPortfolio memory nToken, uint16 currencyId)
        internal
        view
    {
        loadNTokenPortfolioNoCashGroup(nToken, currencyId);
        nToken.cashGroup = CashGroup.buildCashGroupView(currencyId);
    }

    /// @notice Returns the next settle time for the nToken which is 1 quarter away
    function getNextSettleTime(nTokenPortfolio memory nToken) internal pure returns (uint256) {
        if (nToken.lastInitializedTime == 0) return 0;
        return DateTime.getReferenceTime(nToken.lastInitializedTime) + Constants.QUARTER;
    }

    /// @notice Returns the nToken present value denominated in asset terms.
    function getNTokenAssetPV(nTokenPortfolio memory nToken, uint256 blockTime)
        internal
        view
        returns (int256)
    {
        int256 totalAssetPV;
        int256 totalUnderlyingPV;

        {
            uint256 nextSettleTime = getNextSettleTime(nToken);
            // If the first asset maturity has passed (the 3 month), this means that all the LTs must
            // be settled except the 6 month (which is now the 3 month). We don't settle LTs except in
            // initialize markets so we calculate the cash value of the portfolio here.
            if (nextSettleTime <= blockTime) {
                // NOTE: this condition should only be present for a very short amount of time, which is the window between
                // when the markets are no longer tradable at quarter end and when the new markets have been initialized.
                // We time travel back to one second before maturity to value the liquidity tokens. Although this value is
                // not strictly correct the different should be quite slight. We do this to ensure that free collateral checks
                // for withdraws and liquidations can still be processed. If this condition persists for a long period of time then
                // the entire protocol will have serious problems as markets will not be tradable.
                blockTime = nextSettleTime - 1;
            }
        }

        // Since we are not doing a risk adjusted valuation here we do not need to net off residual fCash
        // balances in the future before discounting to present. If we did, then the ifCash assets would
        // have to be in the portfolio array first. PV here is denominated in asset cash terms, not in
        // underlying terms.
        {
            MarketParameters memory market;
            for (uint256 i; i < nToken.portfolioState.storedAssets.length; i++) {
                // NOTE: getLiquidityTokenValue can rewrite fCash values in memory, however, that does not
                // happen in this call because there are no fCash values in the nToken portfolio.
                (int256 assetCashClaim, int256 pv) =
                    AssetHandler.getLiquidityTokenValue(
                        i,
                        nToken.cashGroup,
                        market,
                        nToken.portfolioState.storedAssets,
                        blockTime,
                        false
                    );

                totalAssetPV = totalAssetPV.add(assetCashClaim);
                totalUnderlyingPV = totalUnderlyingPV.add(pv);
            }
        }

        // Then iterate over bitmapped assets and get present value
        // prettier-ignore
        (
            int256 bitmapPv, 
            /* hasDebt */
        ) = BitmapAssetsHandler.getifCashNetPresentValue(
            nToken.tokenAddress,
            nToken.cashGroup.currencyId,
            nToken.lastInitializedTime,
            blockTime,
            nToken.cashGroup,
            false
        );
        totalUnderlyingPV = totalUnderlyingPV.add(bitmapPv);

        // Return the total present value denominated in asset terms
        totalAssetPV = totalAssetPV
            .add(nToken.cashGroup.assetRate.convertFromUnderlying(totalUnderlyingPV))
            .add(nToken.cashBalance);

        return totalAssetPV;
    }

    /**
     * Returns the number of liquidity tokens to withdraw from each market if the nToken
     * has idiosyncratic residuals during nToken redeem. In this case the redeemer will take
     * their cash from the rest of the fCash markets, redeeming around the nToken.
     */
    function getLiquidityTokenWithdraw(
        nTokenPortfolio memory nToken, int256 tokensToRedeem, uint256 blockTime)
        internal
        view
        returns (int256[] memory)
    {
        int256 assetResidualValue = getNTokenResidualValue(nToken, blockTime);
        (int256 totalAssetValueInMarkets, int256[] memory netAssetValueInMarket) = getNTokenMarketValue(nToken, blockTime);
        int256[] memory tokensToWithdraw = new int256[](netAssetValueInMarket.length);

        int256 totalAssetValue = totalAssetValueInMarkets.add(assetResidualValue);
        // This is the amount of PV that the redeem can take.
        int256 assetPVToRedeem = tokensToRedeem.mul(totalAssetValue).div(nToken.totalSupply);

        for (uint256 i; i < netAssetValueInMarket.length; i++) {
            int256 totalTokens = nToken.portfolioState.storedAssets[i].notional;
            // The total asset PV to redeem is:
            //      assetPVToRedeem = (tokensToRedeem * totalAssetValue) / totalSupply
            // Proportion of value to withdraw is: 
            //      valueProportion = netAssetValueInMarket / totalAssetValueInMarkets
            // The redeemer's share is:
            //      redeemerShare = (assetPVToRedeem * valueProportion) / totalAssetValue
            // Converted to liquidity tokens is:
            //      tokensToWithdraw = tokensInMarket * redeemerShare
            // Final math equals:
            //      tokensToWithdraw = (tokensInMarket * assetPVToRedeem * netAssetValueInMarket) / (totalAssetValueInMarkets * totalAssetValue)
            tokensToWithdraw[i] = totalTokens
                .mul(assetPVToRedeem)
                .mul(netAssetValueInMarket[i])
                .div(totalAssetValueInMarkets)
                .div(totalAssetValue);
        }

        return tokensToWithdraw;
    }

    function getNTokenResidualValue(nTokenPortfolio memory nToken, uint256 blockTime) internal view returns (int256) {
        // Get the ifCash bits that are idiosyncratic
        bytes32 ifCashBits = getifCashBits(
            nToken.tokenAddress,
            nToken.cashGroup.currencyId,
            nToken.lastInitializedTime,
            blockTime
        );
        int256 residualValue;
        uint256 bitNum = ifCashBits.getNextBitNum();

        while (bitNum != 0) {
            uint256 maturity = DateTime.getMaturityFromBitNum(nToken.lastInitializedTime, bitNum);
            int256 pv = BitmapAssetsHandler.getPresentValue(
                nToken.tokenAddress,
                nToken.cashGroup.currencyId,
                maturity,
                blockTime,
                nToken.cashGroup,
                true // Use risk adjusted valuation to discount the residual. This will impose a fee on the redeemer
            );
            residualValue = residualValue.add(pv);

            // Turn off the bit and look for the next one
            ifCashBits = ifCashBits.setBit(bitNum, false);
            bitNum = ifCashBits.getNextBitNum();
        }

        // Returns the residual value in asset cash terms
        return nToken.cashGroup.assetRate.convertFromUnderlying(residualValue);
    }

    function getNTokenMarketValue(nTokenPortfolio memory nToken, uint256 blockTime)
        internal
        view
        returns (int256 totalAssetValue, int256[] memory netAssetValueInMarket)
    {
        uint256 numMarkets = nToken.portfolioState.storedAssets.length;
        netAssetValueInMarket = new int256[](numMarkets);

        MarketParameters memory market;
        for (uint256 i; i < numMarkets; i++) {
            // Load the corresponding market into memory
            nToken.cashGroup.loadMarket(market, i + 1, true, blockTime);
            uint256 maturity = nToken.portfolioState.storedAssets[i].maturity;

            // Get the fCash claims and fCash assets
            (int256 assetCashClaim, int256 fCashClaim) =
                AssetHandler.getCashClaims(nToken.portfolioState.storedAssets[i], market);
            int256 fCashNotional = BitmapAssetsHandler.getifCashNotional(
                nToken.tokenAddress,
                nToken.cashGroup.currencyId,
                maturity
            );

            netAssetValueInMarket[i] = assetCashClaim.add(
                nToken.cashGroup.assetRate.convertFromUnderlying(
                    AssetHandler.getPresentfCashValue(
                        fCashClaim.add(fCashNotional),
                        maturity,
                        blockTime,
                        // No need to call cash group for oracle rate, it is up to date here
                        market.oracleRate
                    )
                )
            );

            // Sum the total asset value here to calculate proportions later
            totalAssetValue = totalAssetValue.add(netAssetValueInMarket[i]);
        }
    }

    function getifCashBits(
        address account,
        uint256 currencyId,
        uint256 lastInitializedTime,
        uint256 blockTime
    ) internal view returns (bytes32) {
        bytes32 assetsBitmap = BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
        // lastInitializedTime may have some delta from tRef, we will shift the mask to the right accordingly.
        // We know in this case that lastInitializedTime will be less than the current time and less than a quarter.
        uint256 tRef = DateTime.getReferenceTime(blockTime);
        require(tRef < lastInitializedTime);
        uint256 dayDiff = (lastInitializedTime - tRef) / Constants.DAY;
        require(dayDiff < Constants.DAYS_IN_QUARTER);

        // This will turn off any bits in the assetsBitmap that are in active markets
        return assetsBitmap & ~(Constants.ACTIVE_MARKETS_MASK >> dayDiff);
    }

}
