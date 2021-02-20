// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./Market.sol";
import "./CashGroup.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/BalanceHandler.sol";

/**
 * @notice These parameters are used to determine how much perpetual token to deposit
 * or how to initialize markets.
struct PerpetualTokenParameters {
    // The percent of capital to deposit into each market, ordered by market index starting from 0
    uint[] percentToDeposit;
    // If the market proportion is above this threshold, then the token will lend instead of providing
    // liquidity to bring the rates down and prevent over-leveraging.
    uint[] liquidityThreshold;
}
 */

struct PerpetualTokenPortfolio {
    CashGroupParameters cashGroup;
    MarketParameters[] markets;
    PortfolioState portfolioState;
    BalanceState balanceState;
    address tokenAddress;
}

library PerpetualToken {
    using Market for MarketParameters;
    int internal constant DEPOSIT_PERCENT_BASIS = 1e9;

    /**
     * @notice Returns the currency id for a perpetual token or 0 if the address is not a perpetual
     * token. Used to ensure that the perpetual token cannot accept incoming transfers.
     */
    function perpetualTokenCurrencyId(
        address tokenAddress
    ) internal view returns (uint) {
        bytes32 slot = keccak256(abi.encode(tokenAddress, "perpetual.currencyId"));
        uint currencyId;
        assembly { currencyId := sload(slot) }

        return currencyId;
    }

    /** @notice Returns the perpetual token address for a given currency */
    function getPerpetualTokenAddress(
        uint currencyId
    ) internal view returns (address) {
        bytes32 slot = keccak256(abi.encode(currencyId, "perpetual.address"));
        address tokenAddress;
        assembly { tokenAddress := sload(slot) }
        return tokenAddress;
    }

    /**
     * @notice Called by governance to set the perpetual token address and its reverse lookup
     */
    function setPerpetualTokenAddress(
        uint currencyId,
        address tokenAddress
    ) internal {
        bytes32 slot = keccak256(abi.encode(currencyId, "perpetual.address"));
        assembly { sstore(slot, tokenAddress) }

        slot = keccak256(abi.encode(tokenAddress, "perpetual.currencyId"));
        assembly { sstore(slot, currencyId) }
    }

    /**
     * @notice Returns the array of deposit shares and leverage thresholds for a
     * perpetual liquidity token.
     */
    function getDepositParameters(
        uint currencyId,
        uint maxMarketIndex
    ) internal view returns (int[] memory, int[] memory) {
        uint slot = uint(keccak256(abi.encode(currencyId, "perpetual.deposit.parameters")));
        return _getParameters(slot, maxMarketIndex, false);
    }

    /**
     * @notice Sets the deposit parameters for a perpetual liquidity token. We pack the values in alternating
     * between the two parameters into either one or two storage slots depending on the number of markets. This
     * is to save storage reads when we use the parameters.
     */
    function setDepositParameters(
        uint currencyId,
        uint32[] calldata depositShares,
        uint32[] calldata leverageThresholds
    ) internal {
        uint slot = uint(keccak256(abi.encode(currencyId, "perpetual.deposit.parameters")));

        bytes32 data;
        require(
            depositShares.length <= CashGroup.MAX_TRADED_MARKET_INDEX,
            "PT: deposit share length"
        );

        require(
            depositShares.length == leverageThresholds.length,
            "PT: leverage share length"
        );

        uint shareSum;
        for (uint i; i < depositShares.length; i++) {
            // This cannot overflow in uint 256 with 9 max slots
            shareSum = shareSum + depositShares[i];
            require(leverageThresholds[i] > 0 && leverageThresholds[i] < Market.RATE_PRECISION, "PT: leverage threshold");
        }
        // Deposit shares must not add up to more than 100%. If it less than 100 that means some portion
        // will remain in the cash balance for the perpetual token. This might be something that is desireable
        // to collateralize negative fCash balances
        require(shareSum <= uint(DEPOSIT_PERCENT_BASIS), "PT: deposit shares sum");
        _setParameters(slot, depositShares, leverageThresholds);
    }

    /**
     * @notice Sets the initialization parameters for the markets, these are read only when markets
     * are initialized by the perpetual liquidity token.
     */
    function setInitializationParameters(
        uint currencyId,
        uint32[] calldata rateAnchors,
        uint32[] calldata proportions
    ) internal {
        uint slot = uint(keccak256(abi.encode(currencyId, "perpetual.init.parameters")));
        bytes32 data;
        require(
            rateAnchors.length <= CashGroup.MAX_TRADED_MARKET_INDEX,
            "PT: rate anchors length"
        );

        require(
            proportions.length == rateAnchors.length,
            "PT: proportions length"
        );

        for (uint i; i < rateAnchors.length; i++) {
            // Rate anchors are exchange rates and therefore must be greater than RATE_PRECISION
            // or we will end up with negative interest rates
            require(rateAnchors[i] > Market.RATE_PRECISION, "PT: invalid rate anchor");
            // Proportions must be between zero and the rate precision
            require(proportions[i] > 0 && proportions[i] < Market.RATE_PRECISION, "PT: invalid proportion");
        }

        _setParameters(slot, rateAnchors, proportions);
    }

    /**
     * @notice Returns the array of initialization parameters for a given currency.
     */
    function getInitializationParameters(
        uint currencyId,
        uint maxMarketIndex
    ) internal view returns (int[] memory, int[] memory) {
        uint slot = uint(keccak256(abi.encode(currencyId, "perpetual.init.parameters")));
        return _getParameters(slot, maxMarketIndex, true);
    }

    function _getParameters(
        uint slot,
        uint maxMarketIndex,
        bool noUnset
    ) private view returns (int[] memory, int[] memory) {
        bytes32 data;

        assembly { data := sload(slot) }

        int[] memory array1 = new int[](maxMarketIndex);
        int[] memory array2 = new int[](maxMarketIndex);
        for (uint i; i < maxMarketIndex; i++) {
            array1[i] = int(uint32(uint(data)));
            data = data >> 32;
            array2[i] = int(uint32(uint(data)));
            data = data >> 32;

            if (noUnset) {
                require(array1[i] > 0 && array2[i] > 0, "PT: init value zero");
            }

            if (i == 3 || i == 7) {
                // Load the second slot which occurs after the 4th market index
                slot = slot + 1;
                assembly { data := sload(slot) }
            }
        }

        return (array1, array2);
    }

    function _setParameters(
        uint slot,
        uint32[] calldata array1,
        uint32[] calldata array2
    ) private {
        bytes32 data;
        uint bitShift;
        uint i;
        for (; i < array1.length; i++) {
            // Pack the data into alternating 4 byte slots
            data = data | (bytes32(uint(array1[i])) << bitShift);
            bitShift += 32;

            data = data | (bytes32(uint(array2[i])) << bitShift);
            bitShift += 32;

            if (i == 3 || i == 7) {
                // The first 4 (i == 3) pairs of values will fit into 32 bytes of the first storage slot,
                // after this we move one slot over
                assembly { sstore(slot, data) }
                slot = slot + 1;
                data = 0x00;
                bitShift = 0;
            }
        }

        // Store the data if i is not exactly 4 or 8 (which means it was stored in the first or second slots)
        // when i == 3 or i == 7
        if (i != 4 || i != 8) assembly { sstore(slot, data) }
    }

    /**
     * @notice Given a currency id, will build a perpetual token portfolio object in order to get the value
     * of the portfolio.
     */
    function buildPerpetualTokenPortfolio(
        uint currencyId,
        CashGroupParameters[] memory cashGroups,
        MarketParameters[][] memory markets
    ) internal view returns (PerpetualTokenPortfolio memory) {
        PerpetualTokenPortfolio memory perpToken;
        perpToken.tokenAddress = getPerpetualTokenAddress(currencyId);

        // If the cash group is already loaded then reuse it here
        uint i;
        for (; i < cashGroups.length; i++) {
            if (cashGroups[i].currencyId == currencyId) {
                perpToken.cashGroup = cashGroups[i];
                perpToken.markets = markets[i];
                break;
            }
        }

        if (i == cashGroups.length) {
            // Cash group wasn't found so we load it
            (perpToken.cashGroup, perpToken.markets) = CashGroup.buildCashGroup(currencyId);
        }

        perpToken.portfolioState = PortfolioHandler.buildPortfolioState(perpToken.tokenAddress, 0);
        perpToken.balanceState = BalanceHandler.buildBalanceState(
            perpToken.tokenAddress,
            currencyId,
            Bitmap.setBit(new bytes(currencyId / 8 + 1), currencyId, true)
        );

        return perpToken;
    }

    /**
     * @notice Returns the perpetual token present value denominated in asset terms
    function getPerpetualTokenPV(
        PerpetualTokenPortfolio memory perpToken,
        uint blockTime
    ) internal view returns (int) {
        // If the first asset maturity has passed (the 3 month), this means that all the LTs must
        // be settled. We don't settle LTs except in initialize markets so we calculate the cash value
        // of the portfolio here.
        if (assets[0].maturity < blockTime) {
            // This does an additional storage read of balanceState inside getSettlAssetContextView
            // but that is ok since this will be an edge case. Perpetual tokens should be settled and
            // reinitialized to markets fairly quickly.
            perpToken.balanceState = SettleAssets.getSettleAssetContextView(
                perpToken.tokenAddress,
                perpToken.portfolioState,
                perpToken.balanceState,
                blockTime
            );
        } else {
            int liquidityPV = AssetHandler.getPortfolioValue(
                assets,
                cashGroups,
                markets,
                blockTime,
                false
            );
        }

        // TODO: Then iterate over bitmapped assets and get present value
    }

    function calculateTokensToMint(
        PerpetualTokenPortfolio memory perpToken,
        int assetCashDeposit,
        uint blockTime
    ) internal view returns (uint) {
        int pv = getPerpetualTokenPV(perpToken, blockTime);
        require(pv > 0, "PT: pv value negative");
        require(assetCashDeposit >= 0, "PT: deposit negative");

        return assetCashDeposit.mul(pv).div(TokenHander.INTERNAL_TOKEN_PRECISION);
    }

    function mintPerpetualToken(
        PerpetualTokenPortfolio memory perpToken,
        int assetCashDeposit,
        uint blockTime
    ) internal returns (int) {
        int tokensToMint = calculateTokensToMint(perpToken, assetCashDeposit, blockTime);

        depositIntoPortfolio(
            perpToken,
            assetCashDeposit,
            blockTime
        );

        uint totalPerpTokens = perpetualTokenTotalSupply[perpToken.tokenAddress];
        totalPerpTokens = totalPerpTokens.add(tokensToMint);
        perpetualTokenTotalSupply[perpToken.tokenAddress] = totalPerpTokens;

        return tokensToMint;
    }

    function calculateMarketProportion(
        CashGroupParameters memory cashGroup,
        MarketParameters memory market
    ) internal pure returns (uint) {
        int totalCashUnderlying = cashGroup.assetRate.convertInternalToUnderlying(
            market.totalCurrentCash
        );

        return market.totalfCash
            .mul(Market.RATE_PRECISION)
            .div(market.totalfCash.add(totalCashUnderlying));
    }

    function depositIntoPortfolio(
        PerpetualTokenPortfolio memory perpToken,
        int assetCashDeposit,
        uint blockTime
    ) internal {
        PerpetualTokenParameters memory parameters = getPerpetualTokenParameters(perpToken.tokenAddress);

        for (uint i; i < perpToken.markets.length; i++) {
            uint marketDeposit = assetCashDeposit
                .mul(parameters.percentToDeposit[i])
                .div(PERCENT_BASIS);

            MarketParameters memory market = perpToken.cashGroup.getMarket(
                perpTokens.markets,
                i + 1,
                blockTime,
                true // Needs liquidity to true
            );

            int fCashAmount;
            int proportion = calculateMarketProportion(propToken.cashGroup, market);
            if (proportion > parameters.liquidityThreshold[i]) {
                // TODO: set fCashAmount
                int assetCash;
                (perpTokens.markets[i], assetCash) = perpTokens.markets[i].calculateTrade(
                    perpToken.cashGroup,
                    fCashAmount,
                    timeToMaturity
                );

                require(assetCash > 0, "PT: lend trade failed");
            } else {
                // Add liquidity to the market
                PortfolioAsset memory asset = perpTokens.portfolioState.storedAssets[i];
                int liquidityTokens;
                (liquidityTokens, fCashAmount) = perpTokens.markets[i].addLiquidity(marketDeposit)
                // We expect that all the liquidity tokens are in the portfolio in order.
                require(
                    asset.maturity == perpTokens.markets[i].maturity && AssetHandler.isLiquidityToken(asset.assetType)
                    "PT: invalid liquidity token"
                );

                asset.notional = asset.notional.add(liquidityTokens);
                asset.assetStorageState = AssetStorageState.Update;
            }

            // Update the fCash position
            int notional = ifCashMapping[perpToken.tokenAddress][perpToken.cashGroup.currencyId][perpTokens.markets[i].maturity];
            notional = notional.add(fCashAmount);
            ifCashMapping[perpToken.tokenAddress][perpToken.cashGroup.currencyId][perpTokens.markets[i].maturity] = notional;
        }

        perpTokens.portfolioState.storeAssets();
    }

    function redeemPerpetualToken(
        PerpetualTokenPortfolio memory perpToken,
        uint tokensToRedeem,
        uint blockTime
    ) internal view returns (PortfolioAsset[] memory) {
        require(tokensToRedeem > 0, "PT: invalid token amount");
        uint totalPerpTokens = perpetualTokenTotalSupply[perpToken.tokenAddress];
        PortfolioAsset[] memory newLTs = new PortfolioAsset[](perpToken.portfolioState.storedAssets.length);

        // Transfer LTs
        for (uint i; i < perpToken.portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = perpToken.portfolioState.storedAssets[i];
            newLTs[i].currencyId = asset.currencyId;
            newLTs[i].maturity = asset.maturity;
            newLTs[i].assetType = asset.assetType;

            uint notionalToTransfer = asset.notional.mul(tokensToRedeem).div(totalPerpTokens);
            newLTs[i].notional = notionalToTransfer;
            asset.notional = asset.notional.sub(notionalToTransfer);
            asset.assetStorageState = AssetStorageState.Update;
        }

        // TODO: need to transfer ifCash assets

        perpToken.portfolioState.storeAssets();
        // Remove perpetual tokens from the supply
        totalPerpTokens = totalPerpTokens.sub(tokensToRedeem)
        perpetualTokenTotalSupply[perpToken.tokenAddress] = totalPerpTokens;

        return newLTs;
    }

    /**
     * @notice Generic method for selling idiosyncratic fCash, any account can post standing offers
     * for other accounts to purchase their idiosyncratic fCash.
    function sellifCash(
        address account,
        CashGroupParameters memory cashGroup,
        uint maturity,
        int fCashToTransfer,
        uint blockTime
    ) internal view returns (int) {
        // Can only purchase maturities that are not currently active markets
        require(
            !cashGroup.isValidMaturity(maturity, blockTime),
            "PT: invalid maturity"
        );
        require(fCashToTransfer != 0, "PT: invalid transfer");

        // Update the fCash position
        int fCashAmount = ifCashMapping[perpetualTokenAddress][cashGroup.currencyId][maturity];
        if (fCashAmount == 0) return;

        if (fCashToTransfer > 0) {
            // These are outstanding bids for purchasing ifCash, offer prices are denominated as
            // annualized implied rate
            uint annualizedImpliedRate = ifCashOfferRate[perpetualTokenAddress][cashGroup.currencyId][maturity];
            int exchangeRate = Market.getExchangeRateFromImpliedRate(annualizedImpliedRate, maturity - blockTime);

            // TODO: if this amount is less than some threshold we should just give it all away so that
            // we do not end up with dust
            fCashAmount = fCashAmount.subNoNeg(fCashToTransfer);

            int assetCashRequired = fCashAmount.mul(Market.RATE_PRECISION).div(exchangeRate);
            // TODO: need to update the bitmap if this is zero
            ifCashMapping[perpetualTokenAddress][cashGroup.currencyId][maturity] = fCashAmount;

            // TODO: for perp tokens this asset cash should go back into the portfolio
            return assetCashRequired;
        } else if (fCashToTransfer < 0) {
            // TODO: need to figure this out
        }
    }
     */

}