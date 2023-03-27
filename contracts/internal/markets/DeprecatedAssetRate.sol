// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    AssetRateStorage,
    Token,
    Deprecated_AssetRateParameters,
    PrimeRate
} from "../../global/Types.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {TokenHandler} from "../balances/TokenHandler.sol";
import {PrimeCashExchangeRate} from "../pCash/PrimeCashExchangeRate.sol";
import {AssetRateAdapter} from "../../../interfaces/notional/AssetRateAdapter.sol";

library DeprecatedAssetRate {
    using SafeInt256 for int256;

    int256 private constant CTOKEN_RATE_DECIMALS = 1e18;

    function convertUnderlyingExternalToAsset(
        uint16 currencyId,
        int256 underlyingExternalAmount
    ) internal returns (int256) {
        (AssetRateAdapter rateOracle, /* underlyingDecimalPlaces */) = getAssetRateStorage(currencyId);

        // If rateOracle does not exist this will revert
        int256 rate = rateOracle.getExchangeRateStateful();
        require(rate > 0); // dev: invalid exchange rate

        // Calculation here represents:
        // rateDecimals * balance * underlyingPrecision / rate * internalPrecision
        // NOTE: post deprecation, all asset rate adapters will be cTokens so this will
        // return 8 decimal precision as required.
        return underlyingExternalAmount.mul(CTOKEN_RATE_DECIMALS).div(rate);
    }

    function getAssetRateStorage(uint256 currencyId)
        internal view returns (AssetRateAdapter rateOracle, uint8 underlyingDecimalPlaces) {
        mapping(uint256 => AssetRateStorage) storage store = LibStorage.getAssetRateStorage_deprecated();
        AssetRateStorage storage ar = store[currencyId];
        rateOracle = AssetRateAdapter(ar.rateOracle);
        underlyingDecimalPlaces = ar.underlyingDecimalPlaces;
    }

    /// @notice Returns an adapted asset rate object so that legacy integrations that call the
    /// getCurrencyAndRates and getCashGroupAndAssetRate methods will see an asset rate that is convertable
    /// to prime cash balances.
    function getAdaptedAssetRate(
        uint16 currencyId
    ) internal view returns (Deprecated_AssetRateParameters memory assetRate) {
        // A cToken exchange rate is in the following decimal precision:
        // 1e(18 - 8 + underlyingTokenDecimals)
        // Where: cTokenExchangeRate * cTokenAmount / 1e18 => underlyingAmount

        // A prime cash exchange rate is in DOUBLE_SCALAR_PRECISION
        // where: supplyFactor * primeCashBalance / 1e36 => underlyingAmount

        // Therefore, we convert supply factor down to the cToken exchange rate decimal
        // precision.
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(currencyId);
        int256 cTokenExchangeRateDecimals = underlyingToken.decimals.mul(1e10);
        (PrimeRate memory pr, /* */) = PrimeCashExchangeRate.getPrimeCashRateView(currencyId, block.timestamp);

        assetRate.underlyingDecimals = underlyingToken.decimals;
        assetRate.rate = pr.supplyFactor.mul(cTokenExchangeRateDecimals).div(Constants.DOUBLE_SCALAR_PRECISION);
        // Ensure that this is set to zero since it is unused now.
        assetRate.rateOracle = AssetRateAdapter(address(0));
    }
}
