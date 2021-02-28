// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./Market.sol";
import "./CashGroup.sol";
import "./AssetRate.sol";
import "../storage/TokenHandler.sol";
import "../storage/BitmapAssetsHandler.sol";
import "../storage/SettleAssets.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/BalanceHandler.sol";
import "../math/SafeInt256.sol";

struct PerpetualTokenPortfolio {
    CashGroupParameters cashGroup;
    MarketParameters[] markets;
    PortfolioState portfolioState;
    BalanceState balanceState;
    address tokenAddress;
}

library PerpetualToken {
    using Market for MarketParameters;
    using AssetHandler for PortfolioAsset;
    using AssetRate for AssetRateParameters;
    using PortfolioHandler for PortfolioState;
    using CashGroup for CashGroupParameters;
    using BalanceHandler for BalanceState;
    using SafeInt256 for int;

    int internal constant DEPOSIT_PERCENT_BASIS = 1e9;

    /**
     * @notice Returns the currency id for a perpetual token or 0 if the address is not a perpetual
     * token. Also returns the total supply of the perpetual token.
     */
    function getPerpetualTokenCurrencyIdAndSupply(
        address tokenAddress
    ) internal view returns (uint, uint) {
        bytes32 slot = keccak256(abi.encode(tokenAddress, "perpetual.currencyId"));
        bytes32 data;
        assembly { data := sload(slot) }

        uint currencyId = uint(uint16(uint(data)));
        uint totalSupply = uint(uint96(uint(data >> 16)));

        return (currencyId, totalSupply);
    }

    /**
     * @notice Returns the perpetual token address for a given currency
     * @dev TODO: make this a CREATE2 lookup but would blow up the code size
     */
    function getPerpetualTokenAddress(
        uint currencyId
    ) internal view returns (address) {
        bytes32 slot = keccak256(abi.encode(currencyId, "perpetual.address"));
        address tokenAddress;
        assembly { tokenAddress := sload(slot) }
        return tokenAddress;
    }

    /**
     * @notice Called by governance to set the perpetual token address and its reverse lookup. Cannot be
     * reset once this is set.
     */
    function setPerpetualTokenAddress(
        uint16 currencyId,
        address tokenAddress
    ) internal {
        bytes32 addressSlot = keccak256(abi.encode(currencyId, "perpetual.address"));
        bytes32 currencySlot = keccak256(abi.encode(tokenAddress, "perpetual.currencyId"));

        uint data;
        assembly { data := sload(addressSlot) }
        require(data == 0, "PT: token address exists");
        assembly { data := sload(currencySlot) }
        require(data == 0, "PT: currency exists");

        assembly { sstore(addressSlot, tokenAddress) }
        // This will also initialize the total supply at 0
        assembly { sstore(currencySlot, currencyId) }
    }

    /**
     * @notice Updates the perpetual token supply amount when minting or redeeming.
     */
    function changePerpetualTokenSupply(
        address tokenAddress,
        int netChange
    ) private {
        bytes32 slot = keccak256(abi.encode(tokenAddress, "perpetual.currencyId"));

        (uint currencyId, uint totalSupply) = getPerpetualTokenCurrencyIdAndSupply(tokenAddress);
        int newSupply = int(totalSupply).add(netChange);
        require(newSupply >= 0 && uint(newSupply) < type(uint96).max, "PT: total supply overflow");

        uint96 storedSupply = uint96(newSupply);
        bytes32 data = (
            bytes32(currencyId) |
            bytes32(uint(storedSupply)) << 16
        );

        assembly { sstore(slot, data) }
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
        uint currencyId
    ) internal view returns (PerpetualTokenPortfolio memory) {
        PerpetualTokenPortfolio memory perpToken;
        perpToken.tokenAddress = getPerpetualTokenAddress(currencyId);

        (perpToken.cashGroup, perpToken.markets) = CashGroup.buildCashGroup(currencyId);
        perpToken.portfolioState = PortfolioHandler.buildPortfolioState(perpToken.tokenAddress, 0);
        perpToken.balanceState.currencyId = currencyId;
        (
            perpToken.balanceState.storedCashBalance,
            perpToken.balanceState.storedPerpetualTokenBalance
        ) = BalanceHandler.getBalanceStorage(perpToken.tokenAddress, currencyId);

        return perpToken;
    }

    /**
     * @notice Returns the perpetual token present value denominated in asset terms.
     * @dev We assume that the perpetual token portfolio array is only liquidity tokens and
     * sorted ascending by maturity.
     */
    function getPerpetualTokenPV(
        PerpetualTokenPortfolio memory perpToken,
        AccountStorage memory accountContext,
        uint blockTime
    ) internal view returns (int, bytes memory) {
        int totalAssetPV;
        int totalUnderlyingPV;
        bytes memory ifCashBitmap;

        // If the first asset maturity has passed (the 3 month), this means that all the LTs must
        // be settled except the 6 month (which is now the 3 month). We don't settle LTs except in
        // initialize markets so we calculate the cash value of the portfolio here.
        if (accountContext.nextMaturingAsset <= blockTime) {
            // NOTE: this condition should only be present for a very short amount of time, which is the window between
            // when the markets are no longer tradable at quarter end and when the new markets have been initialized.
            // We time travel back to one second before maturity to value the liquidity tokens. Although this value is
            // not strictly correct the different should be quite slight. We do this to ensure that free collateral checks
            // for withdraws and liquidations can still be processed. If this condition persists for a long period of time then
            // the entire protocol will have serious problems as markets will not be tradable.
            blockTime = accountContext.nextMaturingAsset - 1;
            // Clear the market parameters just in case there is dirty data.
            perpToken.markets = new MarketParameters[](perpToken.markets.length);
        }

        // Since we are not doing a risk adjusted valuation here we do not need to net off residual fCash
        // balances in the future before discounting to present. If we did, then the ifCash assets would
        // have to be in the portfolio array first. PV here is denominated in asset cash terms, not in
        // underlying terms.
        {
            PortfolioAsset[] memory emptyPortfolio = new PortfolioAsset[](0);
            for (uint i; i < perpToken.portfolioState.storedAssets.length; i++) {
                (int assetCashClaim, int pv) = AssetHandler.getLiquidityTokenValue(
                    perpToken.portfolioState.storedAssets[i],
                    perpToken.cashGroup,
                    perpToken.markets,
                    emptyPortfolio,
                    blockTime,
                    false
                );

                totalAssetPV = totalAssetPV.add(assetCashClaim);
                totalUnderlyingPV = totalUnderlyingPV.add(pv);
            }

            // Fetch the ifCash bitmap here beacause it has not been fetched yet.
            ifCashBitmap = BitmapAssetsHandler.getAssetsBitmap(
                perpToken.tokenAddress,
                perpToken.cashGroup.currencyId
            );
        }

        // Then iterate over bitmapped assets and get present value
        totalUnderlyingPV = totalUnderlyingPV.add(
            BitmapAssetsHandler.getifCashNetPresentValue(
                perpToken.tokenAddress,
                perpToken.cashGroup.currencyId,
                accountContext.nextMaturingAsset,
                blockTime,
                ifCashBitmap,
                perpToken.cashGroup,
                perpToken.markets,
                false
            )
        );

        // Return the total present value denominated in asset terms
        return (
            totalAssetPV.add(perpToken.cashGroup.assetRate.convertInternalFromUnderlying(totalUnderlyingPV)),
            ifCashBitmap
        );
    }

    /**
     * @notice Calculates the tokens to mint to the account as a ratio of the perpetual token
     * present value denominated in asset cash terms (as we are depositing in asset cash terms).
     */
    function calculateTokensToMint(
        PerpetualTokenPortfolio memory perpToken,
        AccountStorage memory accountContext,
        int assetCashDeposit,
        uint blockTime
    ) internal view returns (int, bytes memory) {
        if (assetCashDeposit == 0) return (0, new bytes(0));

        // If the account context has not been initialized, that means it has never had assets. In this
        // case we simply use the stored asset balance as the base to calculate the tokens to mint.
        if (accountContext.nextMaturingAsset == 0) {
            // This is for the very first deposit
            if (perpToken.balanceState.storedCashBalance == 0) {
                return (assetCashDeposit, new bytes(0));
            }

            return (
                assetCashDeposit
                    .mul(perpToken.balanceState.storedCashBalance)
                    .div(TokenHandler.INTERNAL_TOKEN_PRECISION),
                new bytes(0)
            );
        }

        // For the sake of simplicity, perpetual tokens cannot be minted if they have assets
        // that need to be settled. This is only done during market initialization in a single step.
        require(accountContext.nextMaturingAsset > blockTime, "PT: requires settlement");

        (int assetCashPV, bytes memory ifCashBitmap) = getPerpetualTokenPV(perpToken, accountContext, blockTime);
        require(assetCashPV >= 0, "PT: pv value negative");
        require(assetCashDeposit >= 0, "PT: deposit negative");

        return (
            assetCashDeposit.mul(assetCashPV).div(TokenHandler.INTERNAL_TOKEN_PRECISION),
            ifCashBitmap
        );
    }

    function mintPerpetualToken(
        PerpetualTokenPortfolio memory perpToken,
        AccountStorage memory accountContext,
        int assetCashDeposit,
        uint blockTime
    ) internal returns (int) {
        (int tokensToMint, bytes memory ifCashBitmap) = calculateTokensToMint(
            perpToken,
            accountContext,
            assetCashDeposit,
            blockTime
        );

        if (accountContext.nextMaturingAsset == 0) {
            // For the initial deposits we simply increment the balanceState, there are no assets.
            perpToken.balanceState.netCashChange = perpToken.balanceState.netCashChange.add(assetCashDeposit);
            // Finalize the balance change here
            perpToken.balanceState.setBalanceStorageForPerpToken(perpToken.tokenAddress);
        } else {
            depositIntoPortfolio(perpToken, accountContext, ifCashBitmap, assetCashDeposit, blockTime);
        }

        // From the calculateTokensToMint function we know that tokensToMint will be positive.
        changePerpetualTokenSupply(perpToken.tokenAddress, tokensToMint);

        return tokensToMint;
    }

    /**
     * @notice Calculates the proportion of totalfCash to totalCashUnderlying for determining
     * whether or not an asset has crossed th leverage threshold.
     */
    function calculateMarketProportion(
        CashGroupParameters memory cashGroup,
        MarketParameters memory market
    ) private pure returns (int) {
        int totalCashUnderlying = cashGroup.assetRate.convertInternalToUnderlying(
            market.totalCurrentCash
        );

        return market.totalfCash
            .mul(Market.RATE_PRECISION)
            .div(market.totalfCash.add(totalCashUnderlying));
    }

    /**
     * @notice Portions out assetCashDeposit into amounts to deposit into individual markets. When
     * entering this method we know that assetCashDeposit is positive and the perpToken has been
     * initialized to have liquidity tokens.
     */
    function depositIntoPortfolio(
        PerpetualTokenPortfolio memory perpToken,
        AccountStorage memory accountContext,
        bytes memory ifCashBitmap,
        int assetCashDeposit,
        uint blockTime
    ) private {
        (int[] memory depositShares, int[] memory leverageThresholds) = getDepositParameters(
            perpToken.cashGroup.currencyId,
            perpToken.cashGroup.maxMarketIndex
        );

        for (uint i; i < perpToken.markets.length; i++) {
            // We know from the call into this method that assetCashDeposit is positive
            int perMarketDeposit = assetCashDeposit
                .mul(depositShares[i])
                .div(DEPOSIT_PERCENT_BASIS);

            MarketParameters memory market = perpToken.cashGroup.getMarket(
                perpToken.markets,
                i + 1, // Market index is 1-indexed
                blockTime,
                true // Needs liquidity to true
            );

            int fCashAmount;
            int proportion = calculateMarketProportion(perpToken.cashGroup, market);
            if (proportion > leverageThresholds[i]) {
                // If the proportion is above the liquidity threshold the perp token will lend to the market
                // instead of providing liquidity in order to ensure that it does not over lever itself.
                int assetCash;
                // TODO: finish this
                // (perpToken.markets[i], assetCash) = lendToMarket(
                //     perpToken.cashGroup,
                //     perpToken.markets,
                //     perMarketDeposit,
                //     blockTime
                // );
                require(assetCash > 0, "PT: lend trade failed");
            } else {
                // Add liquidity to the market
                PortfolioAsset memory asset = perpToken.portfolioState.storedAssets[i];
                // We expect that all the liquidity tokens are in the portfolio in order.
                require(
                       asset.maturity == perpToken.markets[i].maturity
                    // Ensures that the asset type references the proper liquidity token
                    && asset.assetType == i + 2,
                    "PT: invalid liquidity token"
                );

                int liquidityTokens;
                // This will update the market state as well
                (liquidityTokens, fCashAmount) = perpToken.markets[i].addLiquidity(perMarketDeposit);

                asset.notional = asset.notional.add(liquidityTokens);
                asset.storageState = AssetStorageState.Update;
            }

            ifCashBitmap = BitmapAssetsHandler.setifCashAsset(
                perpToken.tokenAddress,
                perpToken.cashGroup.currencyId,
                perpToken.markets[i].maturity,
                accountContext.nextMaturingAsset,
                // fCash amount is denominated in the underlying here as it always is
                fCashAmount,
                ifCashBitmap
            );

            perpToken.markets[i].setMarketStorage(AssetHandler.getSettlementDateViaAssetType(
                i + 2,
                perpToken.markets[i].maturity
            ));
        }

        BitmapAssetsHandler.setAssetsBitmap(perpToken.tokenAddress, perpToken.cashGroup.currencyId, ifCashBitmap);
        // TODO: make storeAssets a library call
        // NOTE: balance state should not change as a result of this method
        // perpToken.portfolioState.storeAssets(assetArrayMapping[perpToken.tokenAddress]);
    }

    /**
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
    */

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