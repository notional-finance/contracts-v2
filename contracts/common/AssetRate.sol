// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./Market.sol";
import "../math/SafeInt256.sol";
import "../storage/StorageLayoutV1.sol";
import "../storage/TokenHandler.sol";
import "../adapters/AssetRateAdapterInterface.sol";
import "interfaces/chainlink/AggregatorV2V3Interface.sol";

/**
 * @dev Asset rate object as stored in memory, these are cached optimistically
 * when the transaction begins. This is not the same as the object in storage.
 */ 
struct AssetRateParameters {
    // Address of the asset rate oracle
    address rateOracle;
    // The exchange rate from base to quote (if invert is required it is already done)
    int rate;
    // The decimals of the underlying, the rate converts to the underlying decimals
    int underlyingDecimals;
}

library AssetRate {
    using SafeInt256 for int256;
    event SetSettlementRate(uint currencyId, uint maturity, uint128 rate);

    uint internal constant ASSET_RATE_STORAGE_SLOT = 2;
    int internal constant ASSET_RATE_DECIMALS = 1e18;

    /**
     * @notice Converts an internal asset value to its underlying token value. Internally, cash and fCash are all specified
     * at Market.RATE_PRECISION so no decimal conversion is necessary here. Conversion is only required when transferring
     * externally from the system.
     *
     * Buffers and haircuts ARE NOT applied here. Asset rates are defined as assetRate * assetBalance = underlyingBalance.
     * Underlying is referred to as the quote currency in these exchange rates. Asset is referred to as the base currency
     * in these exchange rates.
     *
     * @param ar exchange rate object between asset and underlying
     * @param assetBalance amount (denominated in asset value) to convert to underlying
     */
    function convertInternalToUnderlying(
        AssetRateParameters memory ar,
        int assetBalance
    ) internal pure returns (int) {
        if (assetBalance == 0) return 0;

        // Calculation here represents:
        // rateDecimals * balance * internalPrecision / rateDecimals * underlyingPrecision
        int underlyingBalance = ar.rate
            .mul(assetBalance)
            .mul(TokenHandler.INTERNAL_TOKEN_PRECISION)
            .div(ASSET_RATE_DECIMALS)
            .div(ar.underlyingDecimals);

        return underlyingBalance;
    }

    /**
     * @notice Converts an internal asset value to its underlying token value. Internally, cash and fCash are all specified
     * at Market.RATE_PRECISION so no decimal conversion is necessary here. Conversion is only required when transferring
     * externally from the system.
     *
     * Buffers and haircuts ARE NOT applied here. Asset rates are defined as assetRate * assetBalance =
     * underlyingBalance. Underlying is referred to as the quote currency in these exchange rates.
     *
     * @param ar exchange rate object between asset and underlying
     * @param underlyingBalance amount (denominated in internal precision) to convert to asset value
     */
    function convertInternalFromUnderlying(
        AssetRateParameters memory ar,
        int underlyingBalance
    ) internal pure returns (int) {
        if (underlyingBalance == 0) return 0;

        // Calculation here represents:
        // rateDecimals * balance * underlyingPrecision / rateDecimals * internalPrecision
        int assetBalance = underlyingBalance
            .mul(ASSET_RATE_DECIMALS)
            .mul(ar.underlyingDecimals)
            .div(ar.rate)
            .div(TokenHandler.INTERNAL_TOKEN_PRECISION);

        return assetBalance;
    }

    function getSupplyRate(
        AssetRateParameters memory ar
    ) internal view returns (uint) {
        uint rate = AssetRateAdapterInterface(ar.rateOracle).getAnnualizedSupplyRate();
        // TODO: is it possible for the supply rate to be zero?
        require(rate > 0, "AR: invalid supply rate");

        return rate;
    }

    function _getAssetRate(
        uint currencyId
    ) private view returns (int, address, uint8) {
        bytes32 slot = keccak256(abi.encode(currencyId, ASSET_RATE_STORAGE_SLOT));
        bytes32 data;

        assembly { data := sload(slot) }

        address rateOracle = address(bytes20(data << 96));
        uint8 underlyingDecimalPlaces = uint8(uint(data >> 160));
        // TODO: latest round data potentially modifies state
        // TODO: potentially change this such that it takes a currency id and we
        // hardcode a single adapter interface
        int rate = AssetRateAdapterInterface(rateOracle).getExchangeRateView();
        require(rate > 0, "AR: invalid rate");

        return (rate, rateOracle, underlyingDecimalPlaces);
    }

    function buildAssetRate(
        uint currencyId
    ) internal view returns (AssetRateParameters memory) {
        (int rate, address rateOracle, uint8 underlyingDecimalPlaces) = _getAssetRate(currencyId);
        int underlyingDecimals = int(10**underlyingDecimalPlaces);

        return AssetRateParameters({
            rateOracle: rateOracle,
            rate: rate,
            underlyingDecimals: underlyingDecimals
        });
    }

    function buildSettlementRateView(
        uint currencyId,
        uint maturity
    ) internal view returns (AssetRateParameters memory, bytes32, uint8) {
        bytes32 slot = keccak256(abi.encode(currencyId, maturity, "assetRate.settlement"));
        bytes32 data;

        assembly { data := sload(slot) }

        int settlementRate;
        uint8 underlyingDecimalPlaces;
        if (data == bytes32(0)) {
            (settlementRate, /* address */, underlyingDecimalPlaces) = _getAssetRate(currencyId);
        } else {
            settlementRate = int(uint128(uint(data >> 40)));
            underlyingDecimalPlaces = uint8(uint(data >> 168));
            // Set the slot to zero if we don't need to settle
            slot = bytes32(0);
        }
        int underlyingDecimals = int(10**underlyingDecimalPlaces);

        // Rate oracle not required for settlement
        return (
            AssetRateParameters(address(0), settlementRate, underlyingDecimals),
            slot,
            underlyingDecimalPlaces
        );
    }

    function buildSettlementRateStateful(
        uint currencyId,
        uint maturity,
        uint blockTime
    ) internal returns (AssetRateParameters memory) {
        (
            AssetRateParameters memory settlementRate,
            bytes32 slot,
            uint8 underlyingDecimalPlaces
        ) = buildSettlementRateView(currencyId, maturity);

        if (slot != bytes32(0)) {
            require(blockTime != 0 && blockTime <= type(uint40).max); // dev: settlement rate timestamp overflow
            require(settlementRate.rate > 0 && settlementRate.rate <= type(uint128).max); // dev: settlement rate overflow
            uint128 storedRate = uint128(uint(settlementRate.rate));

            bytes32 data = (
                bytes32(blockTime) |
                bytes32(uint(storedRate)) << 40 |
                bytes32(uint(underlyingDecimalPlaces)) << 168
            );

            assembly { sstore(slot, data) }

            emit SetSettlementRate(currencyId, maturity, storedRate);
        }

        return settlementRate;
    }
}
