// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../global/Types.sol";
import "../../global/LibStorage.sol";
import "../../global/Constants.sol";
import "../../math/SafeInt256.sol";
import "../../../interfaces/notional/AssetRateAdapter.sol";

library AssetRate {
    using SafeInt256 for int256;
    event SetSettlementRate(uint256 indexed currencyId, uint256 indexed maturity, uint128 rate);

    // Asset rates are in 1e18 decimals (cToken exchange rates), internal balances
    // are in 1e8 decimals. Therefore we leave this as 1e18 / 1e8 = 1e10
    int256 private constant ASSET_RATE_DECIMAL_DIFFERENCE = 1e10;

    /// @notice Converts an internal asset cash value to its underlying token value.
    /// @param ar exchange rate object between asset and underlying
    /// @param assetBalance amount to convert to underlying
    function convertToUnderlying(AssetRateParameters memory ar, int256 assetBalance)
        internal
        pure
        returns (int256)
    {
        // Calculation here represents:
        // rate * balance * internalPrecision / rateDecimals * underlyingPrecision
        int256 underlyingBalance = ar.rate
            .mul(assetBalance)
            .div(ASSET_RATE_DECIMAL_DIFFERENCE)
            .div(ar.underlyingDecimals);

        return underlyingBalance;
    }

    /// @notice Converts an internal underlying cash value to its asset cash value
    /// @param ar exchange rate object between asset and underlying
    /// @param underlyingBalance amount to convert to asset cash, denominated in internal token precision
    function convertFromUnderlying(AssetRateParameters memory ar, int256 underlyingBalance)
        internal
        pure
        returns (int256)
    {
        // Calculation here represents:
        // rateDecimals * balance * underlyingPrecision / rate * internalPrecision
        int256 assetBalance = underlyingBalance
            .mul(ASSET_RATE_DECIMAL_DIFFERENCE)
            .mul(ar.underlyingDecimals)
            .div(ar.rate);

        return assetBalance;
    }

    /// @notice Returns the current per block supply rate, is used when calculating oracle rates
    /// for idiosyncratic fCash with a shorter duration than the 3 month maturity.
    function getSupplyRate(AssetRateParameters memory ar) internal view returns (uint256) {
        // If the rate oracle is not set, the asset is not interest bearing and has an oracle rate of zero.
        if (address(ar.rateOracle) == address(0)) return 0;

        uint256 rate = ar.rateOracle.getAnnualizedSupplyRate();
        // Zero supply rate is valid since this is an interest rate, we do not divide by
        // the supply rate so we do not get div by zero errors.
        require(rate >= 0); // dev: invalid supply rate

        return rate;
    }

    function _getAssetRateStorage(uint256 currencyId)
        private
        view
        returns (AssetRateAdapter rateOracle, uint8 underlyingDecimalPlaces)
    {
        mapping(uint256 => AssetRateStorage) storage store = LibStorage.getAssetRateStorage();
        AssetRateStorage storage ar = store[currencyId];
        rateOracle = AssetRateAdapter(ar.rateOracle);
        underlyingDecimalPlaces = ar.underlyingDecimalPlaces;
    }

    /// @notice Gets an asset rate using a view function, does not accrue interest so the
    /// exchange rate will not be up to date. Should only be used for non-stateful methods
    function _getAssetRateView(uint256 currencyId)
        private
        view
        returns (
            int256,
            AssetRateAdapter,
            uint8
        )
    {
        (AssetRateAdapter rateOracle, uint8 underlyingDecimalPlaces) = _getAssetRateStorage(currencyId);

        int256 rate;
        if (address(rateOracle) == address(0)) {
            // If no rate oracle is set, then set this to the identity
            rate = ASSET_RATE_DECIMAL_DIFFERENCE;
            // This will get raised to 10^x and return 1, will not end up with div by zero
            underlyingDecimalPlaces = 0;
        } else {
            rate = rateOracle.getExchangeRateView();
            require(rate > 0); // dev: invalid exchange rate
        }

        return (rate, rateOracle, underlyingDecimalPlaces);
    }

    /// @notice Gets an asset rate using a stateful function, accrues interest so the
    /// exchange rate will be up to date for the current block.
    function _getAssetRateStateful(uint256 currencyId)
        private
        returns (
            int256,
            AssetRateAdapter,
            uint8
        )
    {
        (AssetRateAdapter rateOracle, uint8 underlyingDecimalPlaces) = _getAssetRateStorage(currencyId);

        int256 rate;
        if (address(rateOracle) == address(0)) {
            // If no rate oracle is set, then set this to the identity
            rate = ASSET_RATE_DECIMAL_DIFFERENCE;
            // This will get raised to 10^x and return 1, will not end up with div by zero
            underlyingDecimalPlaces = 0;
        } else {
            rate = rateOracle.getExchangeRateStateful();
            require(rate > 0); // dev: invalid exchange rate
        }

        return (rate, rateOracle, underlyingDecimalPlaces);
    }

    /// @notice Returns an asset rate object using the view method
    function buildAssetRateView(uint256 currencyId)
        internal
        view
        returns (AssetRateParameters memory)
    {
        (int256 rate, AssetRateAdapter rateOracle, uint8 underlyingDecimalPlaces) =
            _getAssetRateView(currencyId);

        return
            AssetRateParameters({
                rateOracle: rateOracle,
                rate: rate,
                // No overflow, restricted on storage
                underlyingDecimals: int256(10**underlyingDecimalPlaces)
            });
    }

    /// @notice Returns an asset rate object using the stateful method
    function buildAssetRateStateful(uint256 currencyId)
        internal
        returns (AssetRateParameters memory)
    {
        (int256 rate, AssetRateAdapter rateOracle, uint8 underlyingDecimalPlaces) =
            _getAssetRateStateful(currencyId);

        return
            AssetRateParameters({
                rateOracle: rateOracle,
                rate: rate,
                // No overflow, restricted on storage
                underlyingDecimals: int256(10**underlyingDecimalPlaces)
            });
    }

    /// @dev Gets a settlement rate object
    function _getSettlementRateStorage(uint256 currencyId, uint256 maturity)
        private
        view
        returns (
            int256 settlementRate,
            uint8 underlyingDecimalPlaces
        )
    {
        mapping(uint256 => mapping(uint256 => SettlementRateStorage)) storage store = LibStorage.getSettlementRateStorage();
        SettlementRateStorage storage rateStorage = store[currencyId][maturity];
        settlementRate = rateStorage.settlementRate;
        underlyingDecimalPlaces = rateStorage.underlyingDecimalPlaces;
    }

    /// @notice Returns a settlement rate object using the view method
    function buildSettlementRateView(uint256 currencyId, uint256 maturity)
        internal
        view
        returns (AssetRateParameters memory)
    {
        // prettier-ignore
        (
            int256 settlementRate,
            uint8 underlyingDecimalPlaces
        ) = _getSettlementRateStorage(currencyId, maturity);

        // Asset exchange rates cannot be zero
        if (settlementRate == 0) {
            // If settlement rate has not been set then we need to fetch it
            // prettier-ignore
            (
                settlementRate,
                /* address */,
                underlyingDecimalPlaces
            ) = _getAssetRateView(currencyId);
        }

        return AssetRateParameters(
            AssetRateAdapter(address(0)),
            settlementRate,
            // No overflow, restricted on storage
            int256(10**underlyingDecimalPlaces)
        );
    }

    /// @notice Returns a settlement rate object and sets the rate if it has not been set yet
    function buildSettlementRateStateful(
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) internal returns (AssetRateParameters memory) {
        (int256 settlementRate, uint8 underlyingDecimalPlaces) =
            _getSettlementRateStorage(currencyId, maturity);

        if (settlementRate == 0) {
            // Settlement rate has not yet been set, set it in this branch
            AssetRateAdapter rateOracle;
            // If rate oracle == 0 then this will return the identity settlement rate
            // prettier-ignore
            (
                settlementRate,
                rateOracle,
                underlyingDecimalPlaces
            ) = _getAssetRateStateful(currencyId);

            if (address(rateOracle) != address(0)) {
                mapping(uint256 => mapping(uint256 => SettlementRateStorage)) storage store = LibStorage.getSettlementRateStorage();
                // Only need to set settlement rates when the rate oracle is set (meaning the asset token has
                // a conversion rate to an underlying). If not set then the asset cash always settles to underlying at a 1-1
                // rate since they are the same.
                require(0 < blockTime && maturity <= blockTime && blockTime <= type(uint40).max); // dev: settlement rate timestamp overflow
                require(0 < settlementRate && settlementRate <= type(uint128).max); // dev: settlement rate overflow

                SettlementRateStorage storage rateStorage = store[currencyId][maturity];
                rateStorage.blockTime = uint40(blockTime);
                rateStorage.settlementRate = uint128(settlementRate);
                rateStorage.underlyingDecimalPlaces = underlyingDecimalPlaces;
                emit SetSettlementRate(currencyId, maturity, uint128(settlementRate));
            }
        }

        return AssetRateParameters(
            AssetRateAdapter(address(0)),
            settlementRate,
            // No overflow, restricted on storage
            int256(10**underlyingDecimalPlaces)
        );
    }
}
