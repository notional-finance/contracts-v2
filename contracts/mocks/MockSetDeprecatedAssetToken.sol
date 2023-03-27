// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../global/LibStorage.sol";
import "../global/StorageLayoutV2.sol";
import "../global/Types.sol";
import "../external/patchfix/BasePatchFixRouter.sol";
import {BalanceHandler} from "../internal/balances/BalanceHandler.sol";
import {AssetRateAdapter} from "../../interfaces/notional/AssetRateAdapter.sol";

// Sets deprecated asset token values on the contract for testing
contract MockSetDeprecatedAssetToken is BasePatchFixRouter, StorageLayoutV2 {
    address immutable cETH;
    address immutable cDAI;
    address immutable cUSDC;
    address immutable cWBTC;

    address immutable cETHAdapter;
    address immutable cDAIAdapter;
    address immutable cUSDCAdapter;
    address immutable cWBTCAdapter;

    uint256 internal constant ETH_SCALE = 50;
    uint256 internal constant DAI_SCALE = 49;
    uint256 internal constant USDC_SCALE = 48;
    uint256 internal constant WBTC_SCALE = 47;

    constructor(
        address currentRouter,
        address finalRouter,
        NotionalProxy proxy,
        address _cETH,
        address _cDAI,
        address _cUSDC,
        address _cWBTC,
        address _cETHAdapter,
        address _cDAIAdapter,
        address _cUSDCAdapter,
        address _cWBTCAdapter
    ) BasePatchFixRouter(currentRouter, finalRouter, proxy) {
        cETH = _cETH;
        cDAI = _cDAI;
        cUSDC = _cUSDC;
        cWBTC = _cWBTC;
        cETHAdapter = _cETHAdapter;
        cDAIAdapter = _cDAIAdapter;
        cUSDCAdapter = _cUSDCAdapter;
        cWBTCAdapter = _cWBTCAdapter;
    }

    function _scalePrimeSupply(uint16 currencyId, uint256 scale) private {
        PrimeCashFactorsStorage storage primeStore = LibStorage.getPrimeCashFactors()[currencyId];
        primeStore.totalPrimeSupply = uint88(primeStore.totalPrimeSupply * scale);
        primeStore.underlyingScalar = uint80((
            uint256(primeStore.lastTotalUnderlyingValue) * 1e18
        ) / uint256(primeStore.totalPrimeSupply));

        BalanceHandler.setReserveCashBalance(currencyId, int256(primeStore.totalPrimeSupply));
    }

    function _patchFix() internal override {
        mapping(uint256 => mapping(bool => TokenStorage)) storage store = LibStorage.getTokenStorage();
        mapping(uint256 => AssetRateStorage) storage rateStore = LibStorage.getAssetRateStorage_deprecated();

        store[1][false] = TokenStorage({
            tokenAddress: cETH,
            hasTransferFee: false,
            tokenType: TokenType.cETH,
            decimalPlaces: 8,
            deprecated_maxCollateralBalance: 0
        });
        rateStore[1] = AssetRateStorage({
            rateOracle: AssetRateAdapter(cETHAdapter),
            underlyingDecimalPlaces: 18
        });
        _scalePrimeSupply(1, ETH_SCALE);

        store[2][false] = TokenStorage({
            tokenAddress: cDAI,
            hasTransferFee: false,
            tokenType: TokenType.cToken,
            decimalPlaces: 8,
            deprecated_maxCollateralBalance: 0
        });
        rateStore[2] = AssetRateStorage({
            rateOracle: AssetRateAdapter(cDAIAdapter),
            underlyingDecimalPlaces: 18
        });
        _scalePrimeSupply(2, DAI_SCALE);

        store[3][false] = TokenStorage({
            tokenAddress: cUSDC,
            hasTransferFee: false,
            tokenType: TokenType.cToken,
            decimalPlaces: 8,
            deprecated_maxCollateralBalance: 0
        });
        rateStore[3] = AssetRateStorage({
            rateOracle: AssetRateAdapter(cUSDCAdapter),
            underlyingDecimalPlaces: 6
        });
        _scalePrimeSupply(3, USDC_SCALE);

        store[4][false] = TokenStorage({
            tokenAddress: cWBTC,
            hasTransferFee: false,
            tokenType: TokenType.cToken,
            decimalPlaces: 8,
            deprecated_maxCollateralBalance: 0
        });
        rateStore[4] = AssetRateStorage({
            rateOracle: AssetRateAdapter(cWBTCAdapter),
            underlyingDecimalPlaces: 8
        });
        _scalePrimeSupply(4, WBTC_SCALE);
    }
}