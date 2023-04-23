// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    InterestRateCurveSettings,
    InterestRateParameters,
    CashGroupSettings,
    Token,
    TokenType,
    TokenStorage,
    MarketParameters,
    AssetRateStorage,
    TotalfCashDebtStorage,
    BalanceStorage
} from "../../global/Types.sol";
import {StorageLayoutV2} from "../../global/StorageLayoutV2.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {Deployments} from "../../global/Deployments.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {PrimeCashExchangeRate} from "../../internal/pCash/PrimeCashExchangeRate.sol";
import {InterestRateCurve} from "../../internal/markets/InterestRateCurve.sol";
import {TokenHandler} from "../../internal/balances/TokenHandler.sol";
import {CashGroup} from "../../internal/markets/CashGroup.sol";
import {Market} from "../../internal/markets/Market.sol";
import {DateTime} from "../../internal/markets/DateTime.sol";
import {DeprecatedAssetRate} from "../../internal/markets/DeprecatedAssetRate.sol";

import {nBeaconProxy} from "../../proxy/nBeaconProxy.sol";
import {UpgradeableBeacon} from "../../proxy/beacon/UpgradeableBeacon.sol";
import {BasePatchFixRouter, NotionalProxy} from "./BasePatchFixRouter.sol";

import {IERC20} from "../../../interfaces/IERC20.sol";
import {IPrimeCashHoldingsOracle} from "../../../interfaces/notional/IPrimeCashHoldingsOracle.sol";
import {AssetRateAdapter} from "../../../interfaces/notional/AssetRateAdapter.sol";

contract MigratePrimeCash is BasePatchFixRouter, StorageLayoutV2 {
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using Market for MarketParameters;
    using TokenHandler for Token;

    address internal constant NOTIONAL_MANAGER = 0x02479BFC7Dce53A02e26fE7baea45a0852CB0909;
    // @todo reduce this kink diff once we have more proper values for the tests
    uint256 internal constant MAX_KINK_DIFF = 500 * uint256(1e9 / 10000); // 500 * Constants.BASIS_POINT

    event UpdateCashGroup(uint16 currencyId);

    struct TotalfCashDebt {
        uint40 maturity;
        uint80 totalfCashDebt;
    }

    struct MigrationSettings {
        InterestRateCurveSettings primeDebtCurve;
        IPrimeCashHoldingsOracle primeCashOracle;
        CashGroupSettings cashGroupSettings;
        uint8 rateOracleTimeWindow5Min;
        bool allowPrimeDebt;
        string underlyingName;
        string underlyingSymbol;
        InterestRateCurveSettings[] fCashCurves;
        TotalfCashDebt[] fCashDebts;
    }

    mapping(uint256 => MigrationSettings) internal _migrationSettings;

    constructor(
        address currentRouter,
        address finalRouter,
        NotionalProxy proxy
    ) BasePatchFixRouter(currentRouter, finalRouter, proxy) {}

    function getMigrationSettings(uint256 currencyId) external view returns (MigrationSettings memory) {
        // Must get migration settings outside of a delegate call context. During the _patchFix upgrade,
        // this method will be called inside a delegate call context on the Notional proxy.
        require(address(this) == SELF);
        return _migrationSettings[currencyId];
    }

    /// @notice Sets migration settings on the implementation contract (does not touch the proxy's
    /// storage tree).
    function setMigrationSettings(uint256 currencyId, MigrationSettings memory settings) external {
        // Only the Notional owner can set migration settings
        require(msg.sender == OWNER);
        // Cannot set migration settings inside a delegate call context
        require(address(this) == SELF);
        MigrationSettings storage _storageSettings = _migrationSettings[currencyId];
        _storageSettings.primeDebtCurve = settings.primeDebtCurve;
        _storageSettings.primeCashOracle = settings.primeCashOracle;
        _storageSettings.cashGroupSettings = settings.cashGroupSettings;
        _storageSettings.allowPrimeDebt = settings.allowPrimeDebt;
        _storageSettings.underlyingName = settings.underlyingName;
        _storageSettings.underlyingSymbol = settings.underlyingSymbol;
        _storageSettings.rateOracleTimeWindow5Min = settings.rateOracleTimeWindow5Min;

        // Clear existing array
        uint256 existingLength = _storageSettings.fCashCurves.length;
        for (uint256 i; i < existingLength; i++)  _storageSettings.fCashCurves.pop();

        for (uint256 i; i < settings.fCashCurves.length; i++) {
            _storageSettings.fCashCurves.push(settings.fCashCurves[i]);
        }

        // Clear existing array
        existingLength = _storageSettings.fCashDebts.length;
        for (uint256 i; i < existingLength; i++)  _storageSettings.fCashDebts.pop();

        for (uint256 i; i < settings.fCashDebts.length; i++) {
            _storageSettings.fCashDebts.push(settings.fCashDebts[i]);
        }
    }

    /// @notice Special method for updating the total fCash debt since this may change as we
    /// closer to the actual upgrade
    function updateTotalfCashDebt(uint256 currencyId, TotalfCashDebt[] memory fCashDebts) external {
        // Allow the Notional Manager to set fCash debts closer to upgrade
        require(msg.sender == NOTIONAL_MANAGER);
        // Cannot set migration settings inside a delegate call context
        require(address(this) == SELF);
        MigrationSettings storage _storageSettings = _migrationSettings[currencyId];

        // Clear existing array
        uint256 existingLength = _storageSettings.fCashDebts.length;
        for (uint256 i; i < existingLength; i++)  _storageSettings.fCashDebts.pop();

        for (uint256 i; i < fCashDebts.length; i++) {
            _storageSettings.fCashDebts.push(fCashDebts[i]);
        }
    }

    /// @notice Simulates the fCash curve update outside of a delegate call context so that we can test
    /// the fCash curve update prior to the actual upgrade.
    function simulatefCashCurveUpdate(uint16 currencyId, bool checkRateDiff) external view returns (
        InterestRateCurveSettings[] memory finalCurves,
        uint256[] memory finalRates
    ) {
        MigrationSettings memory settings = this.getMigrationSettings(currencyId);
        (/* */, AssetRateStorage memory ar) = NOTIONAL.getRateStorage(currencyId);
        MarketParameters[] memory markets = NOTIONAL.getActiveMarkets(currencyId);

        // Use the original asset rates to calculate the cash to underlying exchange rates
        int256 assetRateDecimals = int256(10 ** (10 + ar.underlyingDecimalPlaces));
        int256 assetRate = address(ar.rateOracle) != address(0) ? 
            ar.rateOracle.getExchangeRateView() :
            // If rateOracle is not set then use the unit rate
            assetRateDecimals;

        return _calculateInterestRateCurves(
            settings.fCashCurves, markets, checkRateDiff, assetRateDecimals, assetRate
        );
    }

    function getStoredTokenBalances(address[] calldata tokens) external view returns (uint256[] memory balances) {
        mapping(address => uint256) storage store = LibStorage.getStoredTokenBalances();
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = store[tokens[i]];
        }
    }

    /// @notice This method is called during a delegate call context while this contract is the implementation of the
    /// Notional proxy. This happens prior to an upgrade to the final router.
    function _patchFix() internal override {
        // Fixes a bug in the original router where hasInitialized was never set to true,
        // is not exploitable but this will clean it up.
        hasInitialized = true;

        // Loop through all all currencies and init the prime cash curve. `maxCurrencyId` is read
        // from the NotionalProxy storage tree.
        uint16 _maxCurrencies = maxCurrencyId;

        for (uint16 currencyId = 1; currencyId <= _maxCurrencies; currencyId++) {
            MigrationSettings memory settings = MigratePrimeCash(SELF).getMigrationSettings(currencyId);

            // Remaps token addresses to the underlying token
            (Token memory assetToken, Token memory underlyingToken) = _remapTokenAddress(currencyId);

            // Initialize the prime cash curve
            _initializePrimeCash(currencyId, assetToken, underlyingToken, settings);

            // Cash group settings have changed and must be set on migration
            _setCashGroup(currencyId, settings.cashGroupSettings);

            // Initialize the new fCash interest rate curves
            _setfCashInterestRateCurves(currencyId, settings.fCashCurves);

            // Set the total fCash debt outstanding
            _setTotalfCashDebt(currencyId, settings.fCashDebts);

            // The address for the "fee reserve" has changed in v3, migrate the balance
            // from one storage slot to the other
            _setFeeReserveCashBalance(currencyId);
        }
    }

    function _remapTokenAddress(uint16 currencyId) private returns (
        Token memory assetToken,
        Token memory underlyingToken
    ) {
        // If is Non-Mintable, set the underlying token address
        assetToken = TokenHandler.getDeprecatedAssetToken(currencyId);

        if (assetToken.tokenType == TokenType.NonMintable) {
            // Set the underlying token with the same values as the deprecated
            // asset token
            TokenHandler.setToken(currencyId, TokenStorage({
                tokenAddress: assetToken.tokenAddress,
                hasTransferFee: assetToken.hasTransferFee,
                decimalPlaces: IERC20(assetToken.tokenAddress).decimals(),
                tokenType: TokenType.UnderlyingToken,
                deprecated_maxCollateralBalance: 0
            }));
        }

        // Remap the token address to currency id information
        delete tokenAddressToCurrencyId[assetToken.tokenAddress];
        underlyingToken = TokenHandler.getUnderlyingToken(currencyId);

        tokenAddressToCurrencyId[underlyingToken.tokenAddress] = currencyId;
    }

    function _initializePrimeCash(
        uint16 currencyId,
        Token memory assetToken,
        Token memory underlyingToken,
        MigrationSettings memory settings
    ) private {
        // Will set the initial token balance storage to whatever is on the contract at the time
        // of migration.
        PrimeCashExchangeRate.initTokenBalanceStorage(currencyId, settings.primeCashOracle);

        // Any dust underlying token balances will be donated to the prime supply and aggregated into
        // the underlying scalar value. There is currently some dust ETH balance on Notional that will
        // get donated to all prime cash holders.
        uint88 currentAssetTokenBalance = assetToken.convertToInternal(
            IERC20(assetToken.tokenAddress).balanceOf(address(this)).toInt()
        ).toUint().toUint88();

        // NOTE: at time of upgrade there cannot be any negative cash balances. This can be
        // guaranteed by ensuring that all accounts and negative cash balances are settled
        // before the upgrade is executed. There is no way for the contract to verify that
        // this is the case, must rely on governance to ensure that this occurs.
        PrimeCashExchangeRate.initPrimeCashCurve({
            currencyId: currencyId,
            // The initial prime supply will be set by the current balance of the asset tokens
            // in internal precision. currentAssetTokenBalance / currentTotalUnderlying (both in
            // 8 decimal precision) will set the initial basis for the underlyingScalar. This
            // ensures that all existing cash balances remain in the correct precision.
            totalPrimeSupply: currentAssetTokenBalance,
            // These settings must be set on the implementation storage prior to the upgrade.
            debtCurve: settings.primeDebtCurve,
            oracle: settings.primeCashOracle,
            allowDebt: settings.allowPrimeDebt,
            rateOracleTimeWindow5Min: settings.rateOracleTimeWindow5Min
        });

        bytes memory initCallData = abi.encodeWithSignature(
            "initialize(uint16,address,string,string)",
            currencyId,
            underlyingToken.tokenAddress,
            settings.underlyingName,
            settings.underlyingSymbol
        );

        // A beacon proxy gets its implementation via the UpgradeableBeacon set here.
        nBeaconProxy cashProxy = new nBeaconProxy(address(Deployments.PCASH_BEACON), initCallData);
        PrimeCashExchangeRate.setProxyAddress({
            currencyId: currencyId, proxy: address(cashProxy), isCashProxy: true
        });

        if (settings.allowPrimeDebt) {
            nBeaconProxy debtProxy = new nBeaconProxy(address(Deployments.PDEBT_BEACON), initCallData);
            PrimeCashExchangeRate.setProxyAddress({
                currencyId: currencyId, proxy: address(debtProxy), isCashProxy: false
            });
        }
    }

    function _calculateInterestRateCurves(
        InterestRateCurveSettings[] memory fCashCurves,
        MarketParameters[] memory markets,
        bool checkFinalRate,
        int256 assetRateDecimals,
        int256 assetRate
    ) internal pure returns (InterestRateCurveSettings[] memory finalCurves, uint256[] memory finalRates) {
        // These will be the curves that are set in storage after this method exits
        finalCurves = new InterestRateCurveSettings[](fCashCurves.length);
        // This is just used for the external view method
        finalRates = new uint256[](fCashCurves.length);

        for (uint256 i = 0; i < fCashCurves.length; i++) {
            InterestRateCurveSettings memory irCurve = fCashCurves[i];
            MarketParameters memory market = markets[i];
            
            // Interest rate parameter object for local calculations
            uint256 maxRate = InterestRateCurve.calculateMaxRate(irCurve.maxRateUnits);
            InterestRateParameters memory irParams = InterestRateParameters({
                kinkUtilization1: uint256(irCurve.kinkUtilization1) * uint256(Constants.RATE_PRECISION / Constants.PERCENTAGE_DECIMALS),
                kinkUtilization2: uint256(irCurve.kinkUtilization2) * uint256(Constants.RATE_PRECISION / Constants.PERCENTAGE_DECIMALS),
                maxRate: maxRate,
                kinkRate1: maxRate * irCurve.kinkRate1 / 256,
                kinkRate2: maxRate * irCurve.kinkRate2 / 256,
                // Fees are not used in this method
                minFeeRate: 0, maxFeeRate: 0, feeRatePercent: 0
            });

            // Market utilization cannot change because cash / fCash is already set in the market
            uint256 utilization = InterestRateCurve.getfCashUtilization(
                0, market.totalfCash, market.totalPrimeCash.mul(assetRate).div(assetRateDecimals)
            );

            require(utilization < uint256(Constants.RATE_PRECISION), "Over Utilization");
            // Cannot overflow the new market's max rate
            require(market.lastImpliedRate < irParams.maxRate, "Over Max Rate");

            if (utilization <= irParams.kinkUtilization1) {
                // interestRate = (utilization * kinkRate1) / kinkUtilization1
                // kinkRate1 = (interestRate * kinkUtilization1) / utilization
                uint256 newKinkRate1 = market.lastImpliedRate
                    .mul(irParams.kinkUtilization1)
                    .div(utilization);

                // Check that the new curve's kink rate does not excessively diverge from the intended value
                if (checkFinalRate) {
                    require(_absDiff(newKinkRate1, irParams.kinkRate1) < MAX_KINK_DIFF, "Over Diff 1");
                }

                irParams.kinkRate1 = newKinkRate1;
                // Convert the interest rate back to the uint8 storage value
                irCurve.kinkRate1 = (newKinkRate1 * 256 / maxRate).toUint8();
            } else if (utilization < irParams.kinkUtilization2) { // Avoid divide by zero by using strictly less than
                //                (utilization - kinkUtilization1) * (kinkRate2 - kinkRate1) 
                // interestRate = ---------------------------------------------------------- + kinkRate1
                //                            (kinkUtilization2 - kinkUtilization1)
                // ==> 
                //                interestRate * (kinkUtilization2 - kinkUtilization1) - kinkRate2 * (utilization - kinkUtilization1) 
                // kinkRate1 = ------------------------------------------------------------------------------------------------------
                //                                                      (1 - utilization - kinkUtilization1)
                uint256 numerator = market.lastImpliedRate
                    .mulInRatePrecision(irParams.kinkUtilization2.sub(irParams.kinkUtilization1))
                    .sub(irParams.kinkRate2.mulInRatePrecision(utilization.sub(irParams.kinkUtilization1)));
                uint256 denominator = irParams.kinkUtilization2 - utilization; // no overflow checked above
                uint256 newKinkRate1 = numerator.divInRatePrecision(denominator);

                if (checkFinalRate) {
                    require(_absDiff(newKinkRate1, irParams.kinkRate1) < MAX_KINK_DIFF, "Over Diff 2");
                }

                irParams.kinkRate1 = newKinkRate1;
                // Convert the interest rate back to the uint8 storage value
                irCurve.kinkRate1 = (newKinkRate1 * 256 / maxRate).toUint8();
            } else {
                //                (utilization - kinkUtilization2) * (maxRate - kinkRate2) 
                // interestRate = ---------------------------------------------------------- + kinkRate2
                //                                  (1 - kinkUtilization2)
                // ==> 
                //                interestRate * (1 - kinkUtilization2) - maxRate * (utilization - kinkUtilization2) 
                // kinkRate2 = ------------------------------------------------------------------------------------
                //                                          (1 - utilization)
                uint256 numerator = market.lastImpliedRate
                    .mulInRatePrecision(uint256(Constants.RATE_PRECISION).sub(irParams.kinkUtilization2))
                    .sub(irParams.maxRate.mulInRatePrecision(utilization.sub(irParams.kinkUtilization2)));
                uint256 denominator = uint256(Constants.RATE_PRECISION).sub(utilization);
                uint256 newKinkRate2 = numerator.divInRatePrecision(denominator);

                if (checkFinalRate) {
                    require(_absDiff(newKinkRate2, irParams.kinkRate2) < MAX_KINK_DIFF, "Over Diff 3");
                }

                irParams.kinkRate2 = newKinkRate2;
                irCurve.kinkRate2 = (newKinkRate2 * 256 / maxRate).toUint8();
            }

            uint256 newInterestRate = InterestRateCurve.getInterestRate(irParams, utilization);
            if (checkFinalRate) {
                // Check that the next interest rate is very close to the current market rate
                require(_absDiff(newInterestRate, market.lastImpliedRate) < Constants.BASIS_POINT, "Over Final Diff");
            }
            finalCurves[i] = irCurve;
            finalRates[i] = newInterestRate;
        }
    }

    function _setCashGroup(
        uint16 currencyId,
        CashGroupSettings memory cashGroupSettings
    ) private {
        CashGroup.setCashGroupStorage(currencyId, cashGroupSettings);
        emit UpdateCashGroup(currencyId);
    }

    function _setfCashInterestRateCurves(
        uint16 currencyId,
        InterestRateCurveSettings[] memory fCashCurves
    ) private {
        // NOTE: inside this method we are accessing storage values directly since it is inside a delegate call context.
        uint256 maxMarketIndex = CashGroup.getMaxMarketIndex(currencyId);
        require(fCashCurves.length == maxMarketIndex, "market index length");

        MarketParameters[] memory markets = new MarketParameters[](maxMarketIndex);
        for (uint256 i = 0; i < maxMarketIndex; i++) {
            uint256 maturity = DateTime.getReferenceTime(block.timestamp).add(DateTime.getTradedMarket(i + 1));
            // NOTE: oracle rate does not matter in this context, oracleRateWindow is set to a minimum amount
            markets[i].loadMarket(currencyId, maturity, block.timestamp, true, 1);
        }

        // Use the original asset rates to calculate the cash to underlying exchange rates
        (AssetRateAdapter rateOracle, uint8 underlyingDecimalPlaces) = DeprecatedAssetRate.getAssetRateStorage(currencyId);
        int256 assetRateDecimals = int256(10 ** (10 + underlyingDecimalPlaces));
        int256 assetRate = address(rateOracle) != address(0) ? 
            rateOracle.getExchangeRateStateful() :
            // If rateOracle is not set then use the unit rate
            assetRateDecimals;

        (InterestRateCurveSettings[] memory finalCurves, /* */) = _calculateInterestRateCurves(
            fCashCurves,
            markets,
            true, // check interest rate divergence
            assetRateDecimals,
            assetRate
        );

        for (uint256 i; i < finalCurves.length; i++) {
            InterestRateCurve.setNextInterestRateParameters(currencyId, i + 1, finalCurves[i]);
        }

        // Copies the "next interest rate parameters" into the "active" storage slot
        InterestRateCurve.setActiveInterestRateParameters(currencyId);
    }

    /// @notice Sets the total fCash debt outstanding figure which will be used at settlement to
    /// determine the prime cash exchange rate. Prior to the upgrade, Notional will be paused so
    /// that total fCash debt cannot change until this upgrade is completed.
    function _setTotalfCashDebt(uint16 currencyId, TotalfCashDebt[] memory fCashDebts) private {
        mapping(uint256 => mapping(uint256 => TotalfCashDebtStorage)) storage store = LibStorage.getTotalfCashDebtOutstanding();

        for (uint256 i; i < fCashDebts.length; i++) {
            // Only future dated fcash debt should be set
            require(block.timestamp < fCashDebts[i].maturity);
            // Setting the initial fCash amount will not emit any events.
            store[currencyId][fCashDebts[i].maturity].totalfCashDebt = fCashDebts[i].totalfCashDebt;
        }
    }

    function _setFeeReserveCashBalance(uint16 currencyId) internal {
        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage.getBalanceStorage();
        // Notional V2 reserve constant is set at address(0), copy the value to the new reserve constant
        store[Constants.FEE_RESERVE][currencyId] = store[address(0)][currencyId];
        delete store[address(0)][currencyId];
    }

    function _absDiff(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? b - a : a - b;
    }
}