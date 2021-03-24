// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./Market.sol";
import "./CashGroup.sol";
import "./AssetRate.sol";
import "../storage/TokenHandler.sol";
import "../storage/BitmapAssetsHandler.sol";
import "../storage/AccountContextHandler.sol";
import "../storage/PortfolioHandler.sol";
import "../storage/BalanceHandler.sol";
import "../math/SafeInt256.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

struct PerpetualTokenPortfolio {
    CashGroupParameters cashGroup;
    MarketParameters[] markets;
    PortfolioState portfolioState;
    int totalSupply;
    int cashBalance;
    uint lastInitializedTime;
    address tokenAddress;
}

library PerpetualToken {
    using Market for MarketParameters;
    using AssetHandler for PortfolioAsset;
    using AssetRate for AssetRateParameters;
    using PortfolioHandler for PortfolioState;
    using CashGroup for CashGroupParameters;
    using BalanceHandler for BalanceState;
    using AccountContextHandler for AccountStorage;
    using SafeInt256 for int;
    using SafeMath for uint;

    int internal constant DEPOSIT_PERCENT_BASIS = 1e8;

    /**
     * @notice Returns an account context object that is specific to perpetual tokens.
     */
    function getPerpetualTokenContext(
        address tokenAddress
    ) internal view returns (uint, uint, uint, uint8, uint) {
        bytes32 slot = keccak256(abi.encode(tokenAddress, "perpetual.context"));
        bytes32 data;
        assembly { data := sload(slot) }

        uint currencyId = uint(uint16(uint(data)));
        uint totalSupply = uint(uint96(uint(data >> 16)));
        uint incentiveAnnualEmissionRate = uint(uint32(uint(data >> 112)));
        uint8 assetArrayLength = uint8(uint(data >> 144));
        uint lastInitializedTime = uint(uint32(uint(data >> 152)));

        return (currencyId, totalSupply, incentiveAnnualEmissionRate, assetArrayLength, lastInitializedTime);
    }

    /**
     * @notice Returns the perpetual token address for a given currency
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
        bytes32 currencySlot = keccak256(abi.encode(tokenAddress, "perpetual.context"));

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
    ) internal {
        bytes32 slot = keccak256(abi.encode(tokenAddress, "perpetual.context"));
        bytes32 data;
        assembly { data := sload(slot) }
        int totalSupply = int(uint96(uint(data >> 16)));
        int newSupply = totalSupply.add(netChange);

        require(newSupply >= 0 && uint(newSupply) < type(uint96).max, "PT: total supply overflow");

        // Clear the 12 bytes where stored supply will go and OR it in
        data = data & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF000000000000000000000000FFFF;
        data = data | bytes32(uint(newSupply)) << 16;
        assembly { sstore(slot, data) }
    }

    function setIncentiveEmissionRate(
        address tokenAddress,
        uint32 newEmissionsRate
    ) internal {
        bytes32 slot = keccak256(abi.encode(tokenAddress, "perpetual.context"));

        bytes32 data;
        assembly { data := sload(slot) }
        // Clear the 4 bytes where emissions rate will go and OR it in
        data = data & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        data = data | bytes32(uint(newEmissionsRate)) << 112;
        assembly { sstore(slot, data) }
    }

    function setArrayLengthAndInitializedTime(
        address tokenAddress,
        uint8 arrayLength,
        uint lastInitializedTime
    ) internal {
        bytes32 slot = keccak256(abi.encode(tokenAddress, "perpetual.context"));
        require(lastInitializedTime >= 0 && uint(lastInitializedTime) < type(uint32).max); // dev: next settle time overflow

        bytes32 data;
        assembly { data := sload(slot) }
        // Clear the 6 bytes where array length and settle time will go
        data = data & 0xFFFFFFFFFFFFFFFFFF0000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        data = data | bytes32(uint(arrayLength)) << 144;
        data = data | bytes32(uint(lastInitializedTime)) << 152;
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

    function buildPerpetualTokenPortfolioNoCashGroup(
        uint currencyId
    ) internal view returns (PerpetualTokenPortfolio memory) {
        PerpetualTokenPortfolio memory perpToken;
        perpToken.tokenAddress = getPerpetualTokenAddress(currencyId);
        (
            /* currencyId */,
            uint totalSupply,
            /* incentiveRate */,
            uint8 assetArrayLength,
            uint lastInitializedTime
        ) = getPerpetualTokenContext(perpToken.tokenAddress);
        perpToken.lastInitializedTime = lastInitializedTime;
        perpToken.totalSupply = int(totalSupply);

        perpToken.portfolioState = PortfolioHandler.buildPortfolioState(perpToken.tokenAddress, assetArrayLength, 0);
        (
            perpToken.cashBalance,
            /* perpToken.balanceState.storedPerpetualTokenBalance */,
            /* lastIncentiveMint */
        ) = BalanceHandler.getBalanceStorage(perpToken.tokenAddress, currencyId);

        return perpToken;
    }

    /**
     * @notice Given a currency id, will build a perpetual token portfolio object in order to get the value
     * of the portfolio.
     */
    function buildPerpetualTokenPortfolioStateful(
        uint currencyId
    ) internal returns (PerpetualTokenPortfolio memory) {
        PerpetualTokenPortfolio memory perpToken = buildPerpetualTokenPortfolioNoCashGroup(currencyId);
        (perpToken.cashGroup, perpToken.markets) = CashGroup.buildCashGroupStateful(currencyId);

        return perpToken;
    }

    function buildPerpetualTokenPortfolioView(
        uint currencyId
    ) internal view returns (PerpetualTokenPortfolio memory) {
        PerpetualTokenPortfolio memory perpToken = buildPerpetualTokenPortfolioNoCashGroup(currencyId);
        (perpToken.cashGroup, perpToken.markets) = CashGroup.buildCashGroupView(currencyId);

        return perpToken;
    }

    function getNextSettleTime(
        PerpetualTokenPortfolio memory perpToken
    ) internal pure returns (uint) {
        return CashGroup.getReferenceTime(perpToken.lastInitializedTime) + CashGroup.QUARTER;
    }

    /**
     * @notice Returns the perpetual token present value denominated in asset terms.
     * @dev We assume that the perpetual token portfolio array is only liquidity tokens and
     * sorted ascending by maturity.
     */
    function getPerpetualTokenPV(
        PerpetualTokenPortfolio memory perpToken,
        uint blockTime
    ) internal view returns (int, bytes32) {
        int totalAssetPV;
        int totalUnderlyingPV;
        bytes32 ifCashBitmap = BitmapAssetsHandler.getAssetsBitmap(
            perpToken.tokenAddress,
            perpToken.cashGroup.currencyId
        );

        {
            uint nextSettleTime = getNextSettleTime(perpToken);
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
                // Clear the market parameters just in case there is dirty data.
                perpToken.markets = new MarketParameters[](perpToken.markets.length);
            }
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
        }

        // Then iterate over bitmapped assets and get present value
        (int bitmapPv, /* */ ) = BitmapAssetsHandler.getifCashNetPresentValue(
            perpToken.tokenAddress,
            perpToken.cashGroup.currencyId,
            perpToken.lastInitializedTime,
            blockTime,
            ifCashBitmap,
            perpToken.cashGroup,
            perpToken.markets,
            false
        );
        totalUnderlyingPV = totalUnderlyingPV.add(bitmapPv);

        // Return the total present value denominated in asset terms
        totalAssetPV = totalAssetPV
            .add(perpToken.cashGroup.assetRate.convertInternalFromUnderlying(totalUnderlyingPV))
            .add(perpToken.cashBalance);

        return (totalAssetPV, ifCashBitmap);
    }

    /**
     * @notice Calculates the tokens to mint to the account as a ratio of the perpetual token
     * present value denominated in asset cash terms (as we are depositing in asset cash terms).
     */
    function calculateTokensToMint(
        PerpetualTokenPortfolio memory perpToken,
        int assetCashDeposit,
        uint blockTime
    ) internal view returns (int, bytes32) {
        require(assetCashDeposit >= 0); // dev: perpetual token deposit negative
        if (assetCashDeposit == 0) return (0, 0x0);

        if (perpToken.lastInitializedTime != 0) {
            // For the sake of simplicity, perpetual tokens cannot be minted if they have assets
            // that need to be settled. This is only done during market initialization.
            uint nextSettleTime = getNextSettleTime(perpToken);
            require(nextSettleTime > blockTime, "PT: requires settlement");
        }

        (int assetCashPV, bytes32 ifCashBitmap) = getPerpetualTokenPV(perpToken, blockTime);
        require(assetCashPV >= 0, "PT: pv value negative");

        // Allow for the first deposit
        if (perpToken.totalSupply == 0) return (assetCashDeposit, ifCashBitmap);

        return (
            assetCashDeposit.mul(perpToken.totalSupply).div(assetCashPV),
            ifCashBitmap
        );
    }

    function mintPerpetualToken(
        PerpetualTokenPortfolio memory perpToken,
        int assetCashDeposit,
        uint blockTime
    ) internal returns (int) {
        (int tokensToMint, bytes32 ifCashBitmap) = calculateTokensToMint(
            perpToken,
            assetCashDeposit,
            blockTime
        );

        if (perpToken.portfolioState.storedAssets.length == 0) {
            // If the perp token does not have any assets, then the markets must be initialized first.
            perpToken.cashBalance = perpToken.cashBalance.add(assetCashDeposit);
            BalanceHandler.setBalanceStorageForPerpToken(perpToken);
        } else {
            depositIntoPortfolio(perpToken, ifCashBitmap, assetCashDeposit, blockTime);
        }

        // NOTE: token supply change will happen after minting incentives
        return tokensToMint;
    }

    /**
     * @notice Calculates the proportion of totalfCash to totalCashUnderlying for determining
     * whether or not an asset has crossed th leverage threshold.
     */
    function deleverageMarket(
        CashGroupParameters memory cashGroup,
        MarketParameters memory market,
        int leverageThreshold,
        int perMarketDeposit,
        uint blockTime,
        uint marketIndex
    ) private view returns (int, int, bool) {
        {
            int initialTotalCash = cashGroup.assetRate.convertInternalToUnderlying(market.totalCurrentCash);
            int initialProportion = market.totalfCash
                .mul(Market.RATE_PRECISION)
                .div(market.totalfCash.add(initialTotalCash));

            // No lending required
            if (initialProportion < leverageThreshold) return (perMarketDeposit, 0, true);
        }

        // This is the minimum amount of fCash that we expect to be able to lend. Since perMarketDeposit
        // is denominated in assetCash here we don't have to convert to underlying (the ratio between asset cash
        // and totalCurrentCash is the same in either denomination)
        // TODO: change this to be based on implied rates
        int fCashAmount = perMarketDeposit.mul(market.totalfCash).div(market.totalCurrentCash);
        int assetCash = market.calculateTrade(
            cashGroup,
            fCashAmount.neg(),
            market.maturity.sub(blockTime),
            marketIndex
        );

        // This means that the trade failed
        if (assetCash == 0) return (perMarketDeposit, 0, false);

        // Recalculate the proportion after the trade
        int totalCashUnderlying = cashGroup.assetRate.convertInternalToUnderlying(market.totalCurrentCash);
        int proportion = market.totalfCash
            .mul(Market.RATE_PRECISION)
            .div(market.totalfCash.add(totalCashUnderlying));

        // This will never overflow
        return (perMarketDeposit - assetCash, fCashAmount, proportion < leverageThreshold);
    }

    /**
     * @notice Portions out assetCashDeposit into amounts to deposit into individual markets. When
     * entering this method we know that assetCashDeposit is positive and the perpToken has been
     * initialized to have liquidity tokens.
     */
    function depositIntoPortfolio(
        PerpetualTokenPortfolio memory perpToken,
        bytes32 ifCashBitmap,
        int assetCashDeposit,
        uint blockTime
    ) private {
        (int[] memory depositShares, int[] memory leverageThresholds) = getDepositParameters(
            perpToken.cashGroup.currencyId,
            perpToken.cashGroup.maxMarketIndex
        );

        // Loop backwards from the last market to the first market, the reasoning is a little complicated:
        // If we have to deleverage the markets (i.e. lend instead of provide liquidity) we cannot calculate
        // the precise amount of fCash to buy for the perMarketDeposit because the liquidity curve is logit
        // and this cannot be solved for analytically. We do know that longer term maturities will have more
        // slippage and therefore the residual from the perMarketDeposit will be lower as the maturities get
        // closer to the current block time. Any residual cash from lending will be rolled into shorter
        // markets as this loop progresses.
        int residualCash;
        for (uint i = perpToken.markets.length - 1; i >= 0; i--) {
            int fCashAmount;
            MarketParameters memory market = perpToken.cashGroup.getMarket(
                perpToken.markets,
                i + 1, // Market index is 1-indexed
                blockTime,
                true // Needs liquidity to true
            );

            {
                // We know from the call into this method that assetCashDeposit is positive
                int perMarketDeposit = assetCashDeposit
                    .mul(depositShares[i])
                    .div(DEPOSIT_PERCENT_BASIS)
                    .add(residualCash);

                bool shouldProvide;
                (
                    perMarketDeposit,
                    fCashAmount,
                    shouldProvide
                ) = deleverageMarket(
                    perpToken.cashGroup,
                    market,
                    int(leverageThresholds[i]),
                    perMarketDeposit,
                    blockTime,
                    i + 1
                );

                if (shouldProvide) {
                    // Add liquidity to the market
                    PortfolioAsset memory asset = perpToken.portfolioState.storedAssets[i];
                    // We expect that all the liquidity tokens are in the portfolio in order.
                    require(
                        asset.maturity == market.maturity
                        // Ensures that the asset type references the proper liquidity token
                        && asset.assetType == i + 2,
                        "PT: invalid liquidity token"
                    );

                    int liquidityTokens;
                    // This will update the market state as well, fCashAmount returned here is negative
                    (liquidityTokens, fCashAmount) = market.addLiquidity(perMarketDeposit);
                    asset.notional = asset.notional.add(liquidityTokens);
                    asset.storageState = AssetStorageState.Update;
                    residualCash = 0;
                } else {
                    residualCash = perMarketDeposit;
                }
            }

            ifCashBitmap = BitmapAssetsHandler.setifCashAsset(
                perpToken.tokenAddress,
                perpToken.cashGroup.currencyId,
                market.maturity,
                perpToken.lastInitializedTime,
                // fCash amount is negative and denominated in the underlying here as it always is
                fCashAmount,
                ifCashBitmap
            );

            market.setMarketStorage();
            // Reached end of loop
            if (i == 0) break;
        }

        BitmapAssetsHandler.setAssetsBitmap(perpToken.tokenAddress, perpToken.cashGroup.currencyId, ifCashBitmap);
        perpToken.portfolioState.storeAssets(perpToken.tokenAddress);

        // This will occur if the three month market is over levered and we cannot lend into it
        if (residualCash != 0) {
            // Any remaining residual cash will be put into the perpetual token balance and added as liquidity on the
            // next market initialization
            perpToken.cashBalance = perpToken.cashBalance.add(residualCash);
            BalanceHandler.setBalanceStorageForPerpToken(perpToken);
        }
    }

    /**
     * @notice Removes perpetual token assets and returns the net amount of asset cash owed to the account.
     */
    function redeemPerpetualToken(
        PerpetualTokenPortfolio memory perpToken,
        int tokensToRedeem,
        uint blockTime
    ) internal returns (PortfolioAsset[] memory, int) {
        PortfolioAsset[] memory newifCashAssets;
        uint nextSettleTime = getNextSettleTime(perpToken);
        require(nextSettleTime > blockTime, "PT: requires settlement");

        {
            // Get share of ifCash assets to remove
            newifCashAssets = BitmapAssetsHandler.reduceifCashAssetsProportional(
                perpToken.tokenAddress,
                perpToken.cashGroup.currencyId,
                perpToken.lastInitializedTime,
                tokensToRedeem,
                perpToken.totalSupply
            );
        }

        // Get asset cash share for the perp token, if it exists. It is required in balance handler that the
        // perp token can never have a negative cash asset cash balance.
        int assetCashShare = perpToken.cashBalance.mul(tokensToRedeem).div(perpToken.totalSupply);
        if (assetCashShare > 0) {
            perpToken.cashBalance = perpToken.cashBalance.subNoNeg(assetCashShare);
            BalanceHandler.setBalanceStorageForPerpToken(perpToken);
        }

        // Get share of liquidity tokens to remove
        assetCashShare = assetCashShare.add(
            _removeLiquidityTokens(perpToken, newifCashAssets, tokensToRedeem, perpToken.totalSupply, blockTime)
        );

        {
            (
                /* hasDebt */,
                /* currencies */,
                uint8 newStorageLength,
                /* nextSettleTime */
            ) = perpToken.portfolioState.storeAssets(perpToken.tokenAddress);
            // This can happen if the liquidity tokens are redeemed down to zero
            if (perpToken.portfolioState.storedAssets.length != uint(newStorageLength)) {
                setArrayLengthAndInitializedTime(
                    perpToken.tokenAddress,
                    newStorageLength,
                    perpToken.lastInitializedTime
                );
            }
        }

        // NOTE: Token supply change will happen when we finalize balances and after minting of incentives
        return (newifCashAssets, assetCashShare);
    }

    function _removeLiquidityTokens(
        PerpetualTokenPortfolio memory perpToken,
        PortfolioAsset[] memory newifCashAssets,
        int tokensToRedeem,
        int totalSupply,
        uint blockTime
    ) internal view returns (int) {
        uint ifCashIndex;
        int totalAssetCash;

        for (uint i; i < perpToken.portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = perpToken.portfolioState.storedAssets[i];
            int tokensToRemove = asset.notional.mul(tokensToRedeem).div(int(totalSupply));
            asset.notional = asset.notional.sub(tokensToRemove);
            asset.storageState = AssetStorageState.Update;

            perpToken.markets[i] = perpToken.cashGroup.getMarket(perpToken.markets, i + 1, blockTime, true);
            // Remove liquidity from the market
            (int assetCash, int fCash) = perpToken.markets[i].removeLiquidity(tokensToRemove);
            totalAssetCash = totalAssetCash.add(assetCash);

            // We know that there will always be an ifCash asset at the designated maturity because when markets
            // are initialized the perpetual token portfolio must have some amount of net negative fcash.
            // TODO: is this actually true?, we need to ensure that there is an entry here
            while (newifCashAssets[ifCashIndex].maturity != asset.maturity) {
                ifCashIndex += 1;
            }
            newifCashAssets[ifCashIndex].notional = newifCashAssets[ifCashIndex].notional.add(fCash);
        }

        return totalAssetCash;
    }

}