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
    int256 totalSupply;
    int256 cashBalance;
    uint256 lastInitializedTime;
    bytes6 parameters;
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
    using SafeInt256 for int256;
    using SafeMath for uint256;

    int256 internal constant DEPOSIT_PERCENT_BASIS = 1e8;
    uint8 internal constant LIQUIDATION_HAIRCUT_PERCENTAGE = 0;
    uint8 internal constant CASH_WITHHOLDING_BUFFER = 1;
    uint8 internal constant RESIDUAL_PURCHASE_TIME_BUFFER = 2;
    uint8 internal constant PV_HAIRCUT_PERCENTAGE = 3;
    uint8 internal constant RESIDUAL_PURCHASE_INCENTIVE = 4;
    uint8 internal constant ASSET_ARRAY_LENGTH = 5;

    /**
     * @notice Returns an account context object that is specific to perpetual tokens.
     */
    function getPerpetualTokenContext(address tokenAddress)
        internal
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            bytes6
        )
    {
        bytes32 slot = keccak256(abi.encode(tokenAddress, "perpetual.context"));
        bytes32 data;
        assembly {
            data := sload(slot)
        }

        uint256 currencyId = uint256(uint16(uint256(data)));
        uint256 totalSupply = uint256(uint96(uint256(data >> 16)));
        uint256 incentiveAnnualEmissionRate =
            uint256(uint32(uint256(data >> 112)));
        uint256 lastInitializedTime = uint256(uint32(uint256(data >> 144)));
        bytes6 parameters = bytes6(data << 32);

        return (
            currencyId,
            totalSupply,
            incentiveAnnualEmissionRate,
            lastInitializedTime,
            parameters
        );
    }

    /**
     * @notice Returns the perpetual token address for a given currency
     */
    function nTokenAddress(uint256 currencyId) internal view returns (address) {
        bytes32 slot = keccak256(abi.encode(currencyId, "perpetual.address"));
        address tokenAddress;
        assembly {
            tokenAddress := sload(slot)
        }
        return tokenAddress;
    }

    /**
     * @notice Called by governance to set the perpetual token address and its reverse lookup. Cannot be
     * reset once this is set.
     */
    function setPerpetualTokenAddress(uint16 currencyId, address tokenAddress)
        internal
    {
        bytes32 addressSlot =
            keccak256(abi.encode(currencyId, "perpetual.address"));
        bytes32 currencySlot =
            keccak256(abi.encode(tokenAddress, "perpetual.context"));

        uint256 data;
        assembly {
            data := sload(addressSlot)
        }
        require(data == 0, "PT: token address exists");
        assembly {
            data := sload(currencySlot)
        }
        require(data == 0, "PT: currency exists");

        assembly {
            sstore(addressSlot, tokenAddress)
        }
        // This will also initialize the total supply at 0
        assembly {
            sstore(currencySlot, currencyId)
        }
    }

    /**
     * @notice Set perpetual token collateral parameters
     */
    function setPerpetualTokenCollateralParameters(
        address tokenAddress,
        uint8 residualPurchaseIncentive10BPS,
        uint8 pvHaircutPercentage,
        uint8 residualPurchaseTimeBufferHours,
        uint8 cashWithholdingBuffer10BPS,
        uint8 liquidationHaircutPercentage
    ) internal {
        bytes32 slot = keccak256(abi.encode(tokenAddress, "perpetual.context"));
        bytes32 data;
        assembly {
            data := sload(slot)
        }

        require(
            liquidationHaircutPercentage <= CashGroup.PERCENTAGE_DECIMALS,
            "Invalid haircut"
        );
        // The pv haircut percentage must be less than the liquidation percentage or else liquidators will not
        // get profit for liquidating perpetual tokens.
        require(
            pvHaircutPercentage < liquidationHaircutPercentage,
            "Invalid pv haircut"
        );
        // Ensure that the cash withholding buffer is greater than the residual purchase incentive or
        // the perpetual token may not have enough cash to pay accounts to buy its negative ifCash
        require(
            residualPurchaseIncentive10BPS <= cashWithholdingBuffer10BPS,
            "Invalid discounts"
        );

        // Clear the bytes where collateral parameters will go and OR the data in
        data =
            data &
            0xFFFFFFFFFFFFFFFFFF0000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        bytes32 parameters =
            (bytes32(uint256(residualPurchaseIncentive10BPS)) |
                (bytes32(uint256(pvHaircutPercentage)) << 8) |
                (bytes32(uint256(residualPurchaseTimeBufferHours)) << 16) |
                (bytes32(uint256(cashWithholdingBuffer10BPS)) << 24) |
                (bytes32(uint256(liquidationHaircutPercentage)) << 32));
        data = data | (bytes32(parameters) << 184);
        assembly {
            sstore(slot, data)
        }
    }

    /**
     * @notice Updates the perpetual token supply amount when minting or redeeming.
     */
    function changePerpetualTokenSupply(address tokenAddress, int256 netChange)
        internal
    {
        bytes32 slot = keccak256(abi.encode(tokenAddress, "perpetual.context"));
        bytes32 data;
        assembly {
            data := sload(slot)
        }
        int256 totalSupply = int256(uint96(uint256(data >> 16)));
        int256 newSupply = totalSupply.add(netChange);

        require(
            newSupply >= 0 && uint256(newSupply) < type(uint96).max,
            "PT: total supply overflow"
        );

        // Clear the 12 bytes where stored supply will go and OR it in
        data =
            data &
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF000000000000000000000000FFFF;
        data = data | (bytes32(uint256(newSupply)) << 16);
        assembly {
            sstore(slot, data)
        }
    }

    function setIncentiveEmissionRate(
        address tokenAddress,
        uint32 newEmissionsRate
    ) internal {
        bytes32 slot = keccak256(abi.encode(tokenAddress, "perpetual.context"));

        bytes32 data;
        assembly {
            data := sload(slot)
        }
        // Clear the 4 bytes where emissions rate will go and OR it in
        data =
            data &
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        data = data | (bytes32(uint256(newEmissionsRate)) << 112);
        assembly {
            sstore(slot, data)
        }
    }

    function setArrayLengthAndInitializedTime(
        address tokenAddress,
        uint8 arrayLength,
        uint256 lastInitializedTime
    ) internal {
        bytes32 slot = keccak256(abi.encode(tokenAddress, "perpetual.context"));
        require(
            lastInitializedTime >= 0 &&
                uint256(lastInitializedTime) < type(uint32).max
        ); // dev: next settle time overflow

        bytes32 data;
        assembly {
            data := sload(slot)
        }
        // Clear the 6 bytes where array length and settle time will go
        data =
            data &
            0xFFFFFFFFFFFFFFFFFF0000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        data = data | (bytes32(uint256(lastInitializedTime)) << 144);
        data = data | (bytes32(uint256(arrayLength)) << 176);
        assembly {
            sstore(slot, data)
        }
    }

    /**
     * @notice Returns the array of deposit shares and leverage thresholds for a
     * perpetual liquidity token.
     */
    function getDepositParameters(uint256 currencyId, uint256 maxMarketIndex)
        internal
        view
        returns (int256[] memory, int256[] memory)
    {
        uint256 slot =
            uint256(
                keccak256(
                    abi.encode(currencyId, "perpetual.deposit.parameters")
                )
            );
        return _getParameters(slot, maxMarketIndex, false);
    }

    /**
     * @notice Sets the deposit parameters for a perpetual liquidity token. We pack the values in alternating
     * between the two parameters into either one or two storage slots depending on the number of markets. This
     * is to save storage reads when we use the parameters.
     */
    function setDepositParameters(
        uint256 currencyId,
        uint32[] calldata depositShares,
        uint32[] calldata leverageThresholds
    ) internal {
        uint256 slot =
            uint256(
                keccak256(
                    abi.encode(currencyId, "perpetual.deposit.parameters")
                )
            );
        require(
            depositShares.length <= CashGroup.MAX_TRADED_MARKET_INDEX,
            "PT: deposit share length"
        );

        require(
            depositShares.length == leverageThresholds.length,
            "PT: leverage share length"
        );

        uint256 shareSum;
        for (uint256 i; i < depositShares.length; i++) {
            // This cannot overflow in uint 256 with 9 max slots
            shareSum = shareSum + depositShares[i];
            require(
                leverageThresholds[i] > 0 &&
                    leverageThresholds[i] < Market.RATE_PRECISION,
                "PT: leverage threshold"
            );
        }

        // Total deposit share must add up to 100%
        require(
            shareSum == uint256(DEPOSIT_PERCENT_BASIS),
            "PT: deposit shares sum"
        );
        _setParameters(slot, depositShares, leverageThresholds);
    }

    /**
     * @notice Sets the initialization parameters for the markets, these are read only when markets
     * are initialized by the perpetual liquidity token.
     */
    function setInitializationParameters(
        uint256 currencyId,
        uint32[] calldata rateAnchors,
        uint32[] calldata proportions
    ) internal {
        uint256 slot =
            uint256(
                keccak256(abi.encode(currencyId, "perpetual.init.parameters"))
            );
        require(
            rateAnchors.length <= CashGroup.MAX_TRADED_MARKET_INDEX,
            "PT: rate anchors length"
        );

        require(
            proportions.length == rateAnchors.length,
            "PT: proportions length"
        );

        for (uint256 i; i < rateAnchors.length; i++) {
            // Rate anchors are exchange rates and therefore must be greater than RATE_PRECISION
            // or we will end up with negative interest rates
            require(
                rateAnchors[i] > Market.RATE_PRECISION,
                "PT: invalid rate anchor"
            );
            // Proportions must be between zero and the rate precision
            require(
                proportions[i] > 0 && proportions[i] < Market.RATE_PRECISION,
                "PT: invalid proportion"
            );
        }

        _setParameters(slot, rateAnchors, proportions);
    }

    /**
     * @notice Returns the array of initialization parameters for a given currency.
     */
    function getInitializationParameters(
        uint256 currencyId,
        uint256 maxMarketIndex
    ) internal view returns (int256[] memory, int256[] memory) {
        uint256 slot =
            uint256(
                keccak256(abi.encode(currencyId, "perpetual.init.parameters"))
            );
        return _getParameters(slot, maxMarketIndex, true);
    }

    function _getParameters(
        uint256 slot,
        uint256 maxMarketIndex,
        bool noUnset
    ) private view returns (int256[] memory, int256[] memory) {
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        int256[] memory array1 = new int256[](maxMarketIndex);
        int256[] memory array2 = new int256[](maxMarketIndex);
        for (uint256 i; i < maxMarketIndex; i++) {
            array1[i] = int256(uint32(uint256(data)));
            data = data >> 32;
            array2[i] = int256(uint32(uint256(data)));
            data = data >> 32;

            if (noUnset) {
                require(array1[i] > 0 && array2[i] > 0, "PT: init value zero");
            }

            if (i == 3 || i == 7) {
                // Load the second slot which occurs after the 4th market index
                slot = slot + 1;
                assembly {
                    data := sload(slot)
                }
            }
        }

        return (array1, array2);
    }

    function _setParameters(
        uint256 slot,
        uint32[] calldata array1,
        uint32[] calldata array2
    ) private {
        bytes32 data;
        uint256 bitShift;
        uint256 i;
        for (; i < array1.length; i++) {
            // Pack the data into alternating 4 byte slots
            data = data | (bytes32(uint256(array1[i])) << bitShift);
            bitShift += 32;

            data = data | (bytes32(uint256(array2[i])) << bitShift);
            bitShift += 32;

            if (i == 3 || i == 7) {
                // The first 4 (i == 3) pairs of values will fit into 32 bytes of the first storage slot,
                // after this we move one slot over
                assembly {
                    sstore(slot, data)
                }
                slot = slot + 1;
                data = 0x00;
                bitShift = 0;
            }
        }

        // Store the data if i is not exactly 4 or 8 (which means it was stored in the first or second slots)
        // when i == 3 or i == 7
        if (i != 4 || i != 8)
            assembly {
                sstore(slot, data)
            }
    }

    function buildPerpetualTokenPortfolioNoCashGroup(uint256 currencyId)
        internal
        view
        returns (PerpetualTokenPortfolio memory)
    {
        PerpetualTokenPortfolio memory perpToken;
        perpToken.tokenAddress = nTokenAddress(currencyId);
        (
            ,
            /* currencyId */
            uint256 totalSupply,
            ,
            /* incentiveRate */
            uint256 lastInitializedTime,
            bytes6 parameters
        ) = getPerpetualTokenContext(perpToken.tokenAddress);
        perpToken.lastInitializedTime = lastInitializedTime;
        perpToken.totalSupply = int256(totalSupply);
        perpToken.parameters = parameters;

        perpToken.portfolioState = PortfolioHandler.buildPortfolioState(
            perpToken.tokenAddress,
            uint8(parameters[ASSET_ARRAY_LENGTH]),
            0
        );

        (
            perpToken.cashBalance,
            /* perpToken.balanceState.storedPerpetualTokenBalance */
            /* lastIncentiveMint */
            ,

        ) = BalanceHandler.getBalanceStorage(
            perpToken.tokenAddress,
            currencyId
        );

        return perpToken;
    }

    /**
     * @notice Given a currency id, will build a perpetual token portfolio object in order to get the value
     * of the portfolio.
     */
    function buildPerpetualTokenPortfolioStateful(uint256 currencyId)
        internal
        returns (PerpetualTokenPortfolio memory)
    {
        PerpetualTokenPortfolio memory perpToken =
            buildPerpetualTokenPortfolioNoCashGroup(currencyId);
        (perpToken.cashGroup, perpToken.markets) = CashGroup
            .buildCashGroupStateful(currencyId);

        return perpToken;
    }

    function buildPerpetualTokenPortfolioView(uint256 currencyId)
        internal
        view
        returns (PerpetualTokenPortfolio memory)
    {
        PerpetualTokenPortfolio memory perpToken =
            buildPerpetualTokenPortfolioNoCashGroup(currencyId);
        (perpToken.cashGroup, perpToken.markets) = CashGroup.buildCashGroupView(
            currencyId
        );

        return perpToken;
    }

    function getNextSettleTime(PerpetualTokenPortfolio memory perpToken)
        internal
        pure
        returns (uint256)
    {
        return
            CashGroup.getReferenceTime(perpToken.lastInitializedTime) +
            CashGroup.QUARTER;
    }

    /**
     * @notice Returns the perpetual token present value denominated in asset terms.
     * @dev We assume that the perpetual token portfolio array is only liquidity tokens and
     * sorted ascending by maturity.
     */
    function getPerpetualTokenPV(
        PerpetualTokenPortfolio memory perpToken,
        uint256 blockTime
    ) internal view returns (int256, bytes32) {
        int256 totalAssetPV;
        int256 totalUnderlyingPV;
        bytes32 ifCashBitmap =
            BitmapAssetsHandler.getAssetsBitmap(
                perpToken.tokenAddress,
                perpToken.cashGroup.currencyId
            );

        {
            uint256 nextSettleTime = getNextSettleTime(perpToken);
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
                perpToken.markets = new MarketParameters[](
                    perpToken.markets.length
                );
            }
        }

        // Since we are not doing a risk adjusted valuation here we do not need to net off residual fCash
        // balances in the future before discounting to present. If we did, then the ifCash assets would
        // have to be in the portfolio array first. PV here is denominated in asset cash terms, not in
        // underlying terms.
        {
            PortfolioAsset[] memory emptyPortfolio = new PortfolioAsset[](0);
            for (
                uint256 i;
                i < perpToken.portfolioState.storedAssets.length;
                i++
            ) {
                (int256 assetCashClaim, int256 pv) =
                    AssetHandler.getLiquidityTokenValue(
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
        (
            int256 bitmapPv, /* */

        ) =
            BitmapAssetsHandler.getifCashNetPresentValue(
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
            .add(
            perpToken.cashGroup.assetRate.convertInternalFromUnderlying(
                totalUnderlyingPV
            )
        )
            .add(perpToken.cashBalance);

        return (totalAssetPV, ifCashBitmap);
    }
}
