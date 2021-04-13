// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../global/Types.sol";
import "../../global/Constants.sol";
import "../../math/SafeInt256.sol";
import "interfaces/notional/AssetRateAdapter.sol";

library AssetRate {
    using SafeInt256 for int256;
    event SetSettlementRate(uint256 currencyId, uint256 maturity, uint128 rate);

    uint256 private constant ASSET_RATE_STORAGE_SLOT = 2;
    int256 private constant ASSET_RATE_DECIMALS = 1e18;

    /**
     * @notice Converts an internal asset value to its underlying token value. Internally, cash and fCash are all specified
     * at Constants.RATE_PRECISION so no decimal conversion is necessary here. Conversion is only required when transferring
     * externally from the system.
     *
     * Buffers and haircuts ARE NOT applied here. Asset rates are defined as assetRate * assetBalance = underlyingBalance.
     * Underlying is referred to as the quote currency in these exchange rates. Asset is referred to as the base currency
     * in these exchange rates.
     *
     * @param ar exchange rate object between asset and underlying
     * @param assetBalance amount (denominated in asset value) to convert to underlying
     */
    function convertInternalToUnderlying(AssetRateParameters memory ar, int256 assetBalance)
        internal
        pure
        returns (int256)
    {
        if (assetBalance == 0) return 0;

        // Calculation here represents:
        // rateDecimals * balance * internalPrecision / rateDecimals * underlyingPrecision
        int256 underlyingBalance =
            ar
                .rate
                .mul(assetBalance)
                .mul(Constants.INTERNAL_TOKEN_PRECISION)
                .div(ASSET_RATE_DECIMALS)
                .div(ar.underlyingDecimals);

        return underlyingBalance;
    }

    /**
     * @notice Converts an internal asset value to its underlying token value. Internally, cash and fCash are all specified
     * at Constants.RATE_PRECISION so no decimal conversion is necessary here. Conversion is only required when transferring
     * externally from the system.
     *
     * Buffers and haircuts ARE NOT applied here. Asset rates are defined as assetRate * assetBalance =
     * underlyingBalance. Underlying is referred to as the quote currency in these exchange rates.
     *
     * @param ar exchange rate object between asset and underlying
     * @param underlyingBalance amount (denominated in internal precision) to convert to asset value
     */
    function convertInternalFromUnderlying(AssetRateParameters memory ar, int256 underlyingBalance)
        internal
        pure
        returns (int256)
    {
        if (underlyingBalance == 0) return 0;

        // Calculation here represents:
        // rateDecimals * balance * underlyingPrecision / rateDecimals * internalPrecision
        int256 assetBalance =
            underlyingBalance.mul(ASSET_RATE_DECIMALS).mul(ar.underlyingDecimals).div(ar.rate).div(
                Constants.INTERNAL_TOKEN_PRECISION
            );

        return assetBalance;
    }

    function getSupplyRate(AssetRateParameters memory ar) internal view returns (uint256) {
        uint256 rate = AssetRateAdapter(ar.rateOracle).getAnnualizedSupplyRate();
        // TODO: is it possible for the supply rate to be zero?
        require(rate > 0, "AR: invalid supply rate");

        return rate;
    }

    function getAssetRateView(uint256 currencyId)
        private
        view
        returns (
            int256,
            address,
            uint8
        )
    {
        bytes32 slot = keccak256(abi.encode(currencyId, ASSET_RATE_STORAGE_SLOT));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        address rateOracle = address(bytes20(data << 96));
        uint8 underlyingDecimalPlaces = uint8(uint256(data >> 160));
        // TODO: potentially change this such that it takes a currency id and we
        // hardcode a single adapter interface
        // TODO: account for the fact that rateOracle can be set to zero for non
        // convertable assets
        int256 rate = AssetRateAdapter(rateOracle).getExchangeRateView();
        require(rate > 0, "AR: invalid rate");

        return (rate, rateOracle, underlyingDecimalPlaces);
    }

    function getAssetRateStateful(uint256 currencyId)
        private
        returns (
            int256,
            address,
            uint8
        )
    {
        bytes32 slot = keccak256(abi.encode(currencyId, ASSET_RATE_STORAGE_SLOT));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        address rateOracle = address(bytes20(data << 96));
        uint8 underlyingDecimalPlaces = uint8(uint256(data >> 160));
        // TODO: potentially change this such that it takes a currency id and we
        // hardcode a single adapter interface
        int256 rate = AssetRateAdapter(rateOracle).getExchangeRateStateful();
        require(rate > 0, "AR: invalid rate");

        return (rate, rateOracle, underlyingDecimalPlaces);
    }

    function buildAssetRateView(uint256 currencyId)
        internal
        view
        returns (AssetRateParameters memory)
    {
        (int256 rate, address rateOracle, uint8 underlyingDecimalPlaces) =
            getAssetRateView(currencyId);
        int256 underlyingDecimals = int256(10**underlyingDecimalPlaces);

        return
            AssetRateParameters({
                rateOracle: rateOracle,
                rate: rate,
                underlyingDecimals: underlyingDecimals
            });
    }

    function buildAssetRateStateful(uint256 currencyId)
        internal
        returns (AssetRateParameters memory)
    {
        (int256 rate, address rateOracle, uint8 underlyingDecimalPlaces) =
            getAssetRateStateful(currencyId);
        int256 underlyingDecimals = int256(10**underlyingDecimalPlaces);

        return
            AssetRateParameters({
                rateOracle: rateOracle,
                rate: rate,
                underlyingDecimals: underlyingDecimals
            });
    }

    function buildSettlementRateView(uint256 currencyId, uint256 maturity)
        internal
        view
        returns (AssetRateParameters memory)
    {
        bytes32 slot = keccak256(abi.encode(currencyId, maturity, "assetRate.settlement"));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        int256 settlementRate;
        uint8 underlyingDecimalPlaces;
        if (data == bytes32(0)) {
            (
                settlementRate, /* address */
                ,
                underlyingDecimalPlaces
            ) = getAssetRateView(currencyId);
        } else {
            settlementRate = int256(uint128(uint256(data >> 40)));
            underlyingDecimalPlaces = uint8(uint256(data >> 168));
            // Set the slot to zero if we don't need to settle
            slot = bytes32(0);
        }
        int256 underlyingDecimals = int256(10**underlyingDecimalPlaces);

        // Rate oracle not required for settlement
        return AssetRateParameters(address(0), settlementRate, underlyingDecimals);
    }

    function buildSettlementRateStateful(
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) internal returns (AssetRateParameters memory) {
        bytes32 slot = keccak256(abi.encode(currencyId, maturity, "assetRate.settlement"));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        int256 settlementRate;
        uint8 underlyingDecimalPlaces;
        if (data == bytes32(0)) {
            (
                settlementRate, /* address */
                ,
                underlyingDecimalPlaces
            ) = getAssetRateStateful(currencyId);

            require(blockTime != 0 && blockTime <= type(uint40).max); // dev: settlement rate timestamp overflow
            require(settlementRate > 0 && settlementRate <= type(uint128).max); // dev: settlement rate overflow
            uint128 storedRate = uint128(uint256(settlementRate));

            data = (bytes32(blockTime) |
                (bytes32(uint256(storedRate)) << 40) |
                (bytes32(uint256(underlyingDecimalPlaces)) << 168));

            assembly {
                sstore(slot, data)
            }

            emit SetSettlementRate(currencyId, maturity, storedRate);
        } else {
            settlementRate = int256(uint128(uint256(data >> 40)));
            underlyingDecimalPlaces = uint8(uint256(data >> 168));
        }

        int256 underlyingDecimals = int256(10**underlyingDecimalPlaces);

        return AssetRateParameters(address(0), settlementRate, underlyingDecimals);
    }
}
