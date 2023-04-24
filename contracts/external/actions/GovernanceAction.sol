// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    CashGroupSettings,
    TokenStorage,
    ETHRateStorage,
    InterestRateCurveSettings,
    Token
} from "../../global/Types.sol";
import {StorageLayoutV2} from "../../global/StorageLayoutV2.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {Deployments} from "../../global/Deployments.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

import {ExchangeRate} from "../../internal/valuation/ExchangeRate.sol";
import {CashGroup} from "../../internal/markets/CashGroup.sol";
import {nTokenHandler} from "../../internal/nToken/nTokenHandler.sol";
import {nTokenSupply} from "../../internal/nToken/nTokenSupply.sol";
import {TokenHandler} from "../../internal/balances/TokenHandler.sol";
import {BalanceHandler} from "../../internal/balances/BalanceHandler.sol";
import {PrimeCashExchangeRate} from "../../internal/pCash/PrimeCashExchangeRate.sol";
import {InterestRateCurve} from "../../internal/markets/InterestRateCurve.sol";

import "@openzeppelin/contracts/utils/Address.sol";
import {ActionGuards} from "./ActionGuards.sol";

// Proxies
import {UUPSUpgradeable} from "../../proxy/utils/UUPSUpgradeable.sol";
import {nBeaconProxy} from "../../proxy/nBeaconProxy.sol";
import {IUpgradeableBeacon} from "../../proxy/beacon/IBeacon.sol";

// Interfaces
import {IRewarder} from "../../../interfaces/notional/IRewarder.sol";
import {AggregatorV2V3Interface} from "../../../interfaces/chainlink/AggregatorV2V3Interface.sol";
import {NotionalGovernance} from "../../../interfaces/notional/NotionalGovernance.sol";
import {IPrimeCashHoldingsOracle} from "../../../interfaces/notional/IPrimeCashHoldingsOracle.sol";

/// @notice Governance methods can only be called by the governance contract
contract GovernanceAction is StorageLayoutV2, NotionalGovernance, UUPSUpgradeable, ActionGuards {

    /// @notice Transfers ownership to `newOwner`. Either directly or claimable by the new pending owner.
    /// Can only be invoked by the current `owner`.
    /// @param newOwner Address of the new owner.
    /// @param direct True if `newOwner` should be set immediately. False if `newOwner` needs to use `claimOwnership`.
    function transferOwnership(
        address newOwner,
        bool direct
    ) external override onlyOwner {
        if (direct) {
            // Checks
            require(newOwner != address(0), "Ownable: zero address");

            // Effects
            emit OwnershipTransferred(owner, newOwner);
            owner = newOwner;
            pendingOwner = address(0);
        } else {
            // Effects
            pendingOwner = newOwner;
        }
    }

    /// @notice Needs to be called by `pendingOwner` to claim ownership.
    function claimOwnership() external override {
        address _pendingOwner = pendingOwner;

        // Checks
        require(msg.sender == _pendingOwner, "Ownable: caller != pending owner");

        // Effects
        emit OwnershipTransferred(owner, _pendingOwner);
        owner = _pendingOwner;
        pendingOwner = address(0);
    }

    /// @dev Only the owner may upgrade the contract, the pauseGuardian may downgrade the contract
    /// to a predetermined router contract that provides read only access to the system.
    function _authorizeUpgrade(address newImplementation) internal override {
        require(
            owner == msg.sender ||
            (msg.sender == pauseGuardian && newImplementation == pauseRouter),
            "Unauthorized upgrade"
        );

        // This is set temporarily during a downgrade to the pauseRouter so that the upgrade
        // will pass _authorizeUpgrade on the pauseRouter during the UUPSUpgradeable rollback check
        if (newImplementation == pauseRouter) rollbackRouterImplementation = _getImplementation();
    }

    /// @notice Allows Notional governance to upgrade various Beacon proxies external to the system
    function upgradeBeacon(Deployments.BeaconType proxy, address newBeacon) external override onlyOwner {
        IUpgradeableBeacon beacon;
        if (proxy == Deployments.BeaconType.NTOKEN) {
            beacon = Deployments.NTOKEN_BEACON;
        } else if (proxy == Deployments.BeaconType.PCASH) {
            beacon = Deployments.PCASH_BEACON;
        } else if (proxy == Deployments.BeaconType.WRAPPED_FCASH) {
            beacon = Deployments.WRAPPED_FCASH_BEACON;
        } else {
            revert();
        }

        beacon.upgradeTo(newBeacon);
    }

    /// @notice Sets a new pause router and guardian address.
    function setPauseRouterAndGuardian(
        address pauseRouter_,
        address pauseGuardian_
    ) external override onlyOwner {
        pauseRouter = pauseRouter_;
        pauseGuardian = pauseGuardian_;

        emit PauseRouterAndGuardianUpdated(pauseRouter_, pauseGuardian_);
    }

    /// @notice Lists a new currency along with its exchange rate to ETH
    /// @dev emit:ListCurrency emit:UpdateETHRate
    /// @param underlyingToken the underlying token (if asset token is an interest bearing wrapper)
    /// @return the new currency id
    function listCurrency(
        TokenStorage calldata underlyingToken,
        ETHRateStorage memory ethRate,
        InterestRateCurveSettings calldata primeDebtCurve,
        IPrimeCashHoldingsOracle primeCashHoldingsOracle,
        bool allowPrimeCashDebt,
        uint8 rateOracleTimeWindow5Min,
        string calldata underlyingName,
        string calldata underlyingSymbol
    ) external override onlyOwner returns (uint16) {
        uint16 currencyId = maxCurrencyId + 1;
        // Set the new max currency id
        maxCurrencyId = currencyId;
        require(currencyId <= Constants.MAX_CURRENCIES);
        require(tokenAddressToCurrencyId[underlyingToken.tokenAddress] == 0); // dev: duplicate listing
        tokenAddressToCurrencyId[underlyingToken.tokenAddress] = currencyId;

        // NOTE: set token will enforce the restriction that Ether can only be set once as the zero
        // address. This sets the underlying token
        TokenHandler.setToken(currencyId, underlyingToken);

        // rateDecimalPlaces will be set inside this method
        _updateETHRate(currencyId, ethRate);

        // Since we use internal balance tracking to mitigate donation type exploits,
        // the first time a prime cash curve is initialized we have to set the initial
        // balances in order to get currentTotalUnderlying.
        PrimeCashExchangeRate.initTokenBalanceStorage(currencyId, primeCashHoldingsOracle);

        // This must return some positive amount of the given token in order to initialize
        // the total supply value
        (/* */, uint256 initialPrimeSupply) = primeCashHoldingsOracle
            .getTotalUnderlyingValueStateful();

        PrimeCashExchangeRate.initPrimeCashCurve(
            currencyId,
            SafeUint256.toUint88(initialPrimeSupply),
            primeDebtCurve,
            primeCashHoldingsOracle,
            allowPrimeCashDebt,
            rateOracleTimeWindow5Min
        );

        bytes memory initCallData = abi.encodeWithSignature(
            "initialize(uint16,address,string,string)",
            currencyId,
            underlyingToken.tokenAddress, 
            underlyingName,
            underlyingSymbol
        );

        // A beacon proxy gets its implementation via the UpgradeableBeacon set here.
        nBeaconProxy cashProxy = new nBeaconProxy(address(Deployments.PCASH_BEACON), initCallData);
        PrimeCashExchangeRate.setProxyAddress({
            currencyId: currencyId, proxy: address(cashProxy), isCashProxy: true
        });

        if (allowPrimeCashDebt) {
            nBeaconProxy debtProxy = new nBeaconProxy(address(Deployments.PDEBT_BEACON), initCallData);
            PrimeCashExchangeRate.setProxyAddress({
                currencyId: currencyId, proxy: address(debtProxy), isCashProxy: false
            });
        }

        // Set the reserve cash balance to the initial donation, must be done after proxies are set
        // no overflow possible due to toUint88 check above
        BalanceHandler.setReserveCashBalance(currencyId, int256(initialPrimeSupply));

        emit ListCurrency(currencyId);

        return currencyId;
    }

    /// @notice Enables a cash group on a given currency so that it can have lend and borrow markets. Will
    /// also deploy an nToken contract so that markets can be initialized.
    /// @dev emit:UpdateCashGroup emit:UpdateAssetRate emit:DeployNToken
    /// @param currencyId id of the currency to enable
    /// @param cashGroup parameters for the cash group
    /// @param underlyingName underlying token name for seeding nToken name
    /// @param underlyingSymbol underlying token symbol for seeding nToken symbol (i.e. nDAI)
    function enableCashGroup(
        uint16 currencyId,
        CashGroupSettings calldata cashGroup,
        string calldata underlyingName,
        string calldata underlyingSymbol
    ) external override onlyOwner {
        _checkValidCurrency(currencyId);
        _updateCashGroup(currencyId, cashGroup);

        Token memory underlyingToken = TokenHandler.getUnderlyingToken(currencyId);

        // This must be set to true to enable cash groups.
        require(PrimeCashExchangeRate.doesAllowPrimeDebt(currencyId));

        // Creates the nToken erc20 proxy that routes back to the main contract
        bytes memory initCallData = abi.encodeWithSignature(
            "initialize(uint16,address,string,string)",
            currencyId,
            underlyingToken.tokenAddress,
            underlyingName,
            underlyingSymbol
        );

        // A beacon proxy gets its implementation via the UpgradeableBeacon set here.
        nBeaconProxy proxy = new nBeaconProxy(address(Deployments.NTOKEN_BEACON), initCallData);
        nTokenHandler.setNTokenAddress(currencyId, address(proxy));

        emit DeployNToken(currencyId, address(proxy));
    }

    function setMaxUnderlyingSupply(
        uint16 currencyId,
        uint256 maxUnderlyingSupply
    ) external override onlyOwner {
        uint256 unpackedSupply = PrimeCashExchangeRate.setMaxUnderlyingSupply(currencyId, maxUnderlyingSupply);
        emit UpdateMaxUnderlyingSupply(currencyId, unpackedSupply);
    }

    function updatePrimeCashHoldingsOracle(
        uint16 currencyId,
        IPrimeCashHoldingsOracle primeCashHoldingsOracle
    ) external override onlyOwner {
        PrimeCashExchangeRate.updatePrimeCashHoldingsOracle(currencyId, primeCashHoldingsOracle);
    }

    function updatePrimeCashCurve(
        uint16 currencyId,
        InterestRateCurveSettings calldata primeDebtCurve
    ) external override onlyOwner {
        PrimeCashExchangeRate.updatePrimeCashCurve(currencyId, primeDebtCurve);
    }

    function enablePrimeDebt(
        uint16 currencyId,
        string calldata underlyingName,
        string calldata underlyingSymbol
    ) external override onlyOwner {
        PrimeCashExchangeRate.allowPrimeDebt(currencyId);

        // Deploy the prime debt proxy
        Token memory underlyingToken = TokenHandler.getUnderlyingToken(currencyId);

        bytes memory initCallData = abi.encodeWithSignature(
            "initialize(uint16,address,string,string)",
            currencyId,
            underlyingToken.tokenAddress, 
            underlyingName,
            underlyingSymbol
        );

        nBeaconProxy debtProxy = new nBeaconProxy(address(Deployments.PDEBT_BEACON), initCallData);
        PrimeCashExchangeRate.setProxyAddress({
            currencyId: currencyId, proxy: address(debtProxy), isCashProxy: false
        });
    }

    /// @notice Updates the deposit parameters for an nToken
    /// @dev emit:UpdateDepositParameters
    /// @param currencyId the currency id that the nToken references
    /// @param depositShares an array of values that represent the proportion of each deposit
    /// that will go to a respective market, must add up to DEPOSIT_PERCENT_BASIS. For example,
    /// 0.40e8, 0.40e8 and 0.20e8 will result in 40%, 40% and 20% deposited as liquidity into
    /// the 3 month, 6 month and 1 year markets.
    /// @param leverageThresholds an array of values denominated in RATE_PRECISION that mark the
    /// highest proportion of fCash where the nToken will provide liquidity. Above this proportion,
    /// the nToken will lend to the market instead to reduce the leverage in the market.
    function updateDepositParameters(
        uint16 currencyId,
        uint32[] calldata depositShares,
        uint32[] calldata leverageThresholds
    ) external override onlyOwner {
        _checkValidCurrency(currencyId);
        nTokenHandler.setDepositParameters(currencyId, depositShares, leverageThresholds);
        emit UpdateDepositParameters(currencyId);
    }

    /// @notice Updates the interest rate curve parameters that will take effect after the next market
    /// initialization.
    /// @dev emit:UpdateInterestRateCurve
    /// @param currencyId the currency id to update
    /// @param marketIndices a list of market indices to update the settings for
    /// @param settings the settings for the interest rate curve that will be set on the next
    /// market initialization for the interest rate curve, corresponding to the marketIndices
    function updateInterestRateCurve(
        uint16 currencyId,
        uint8[] calldata marketIndices,
        InterestRateCurveSettings[] calldata settings
    ) external override onlyOwner {
        _checkValidCurrency(currencyId);
        uint8 maxMarketIndex = CashGroup.getMaxMarketIndex(currencyId);
        require(marketIndices.length == settings.length);

        for (uint256 i = 0; i < marketIndices.length; i++) {
            require(0 < marketIndices[i]);
            require(marketIndices[i] <= maxMarketIndex);
            // Require that marketIndices are sorted so that we do not get
            // any duplicates on accident.
            if (i > 0) require(marketIndices[i - 1] < marketIndices[i]);

            InterestRateCurve.setNextInterestRateParameters(
                currencyId,
                marketIndices[i],
                settings[i]
            );

            emit UpdateInterestRateCurve(currencyId, marketIndices[i]);
        }
    }

    /// @notice Updates the market initialization parameters for an nToken
    /// @dev emit:UpdateInitializationParameters
    /// @param currencyId the currency id that the nToken references
    /// @param annualizedAnchorRates is a target interest rate that will be used to calculate a 
    /// rate anchor during initialize markets. This rate anchor will set the offset from the
    /// x-axis where the liquidity curve will be initialized. This is used in combination with
    /// previous market rates to determine the initial proportion where markets will be initialized
    /// every quarter.
    /// @param proportions used to combination with annualizedAnchorRate set the initial proportion when
    /// a market is first initialized. This is required since there is no previous rate to reference.
    function updateInitializationParameters(
        uint16 currencyId,
        uint32[] calldata annualizedAnchorRates,
        uint32[] calldata proportions
    ) external override onlyOwner {
        _checkValidCurrency(currencyId);
        nTokenHandler.setInitializationParameters(currencyId, annualizedAnchorRates, proportions);
        emit UpdateInitializationParameters(currencyId);
    }

    /// @notice Updates collateralization parameters for an nToken
    /// @dev emit:UpdateTokenCollateralParameters
    /// @param currencyId the currency id that the nToken references
    /// @param residualPurchaseIncentive10BPS nTokens will have residual amounts of fCash at the end of each
    /// quarter that are "dead weight" because they are at idiosyncratic maturities and do not contribute to
    /// actively providing liquidity. This parameter will incentivize market participants to purchase these residuals
    /// at a discount from the on chain oracle rate, denominated in 10 basis point increments. These residuals will
    /// be added back into nToken balances and will be used to provide liquidity upon the next market initialization.
    /// @param pvHaircutPercentage a percentage (< 100) that the present value of the nToken's assets will be valued
    /// at for the purposes of free collateral, relevant when accounts hold nTokens as collateral against debts.
    /// @param residualPurchaseTimeBufferHours an arbitrage opportunity is available by pushing markets in one direction
    /// before quarterly settlement to generate large residual balances that can be purchased at a discount. The time buffer
    /// here ensures that anyone attempting such an act would have to wait some number of hours (likely a few days) before
    /// they could attempt to purchase residuals, ensuring that the market could realign to rates where the arbitrage is
    /// no longer possible.
    /// @param cashWithholdingBuffer10BPS nToken residuals may be negative fCash (debt), in this case cash is withheld to
    /// transfer to accounts that take on the debt. This parameter denominates the discounted rate at which the cash will
    /// be withheld at for this purpose.
    /// @param liquidationHaircutPercentage a percentage of nToken present value (> pvHaircutPercentage and <= 100) at which
    /// liquidators will purchase nTokens during liquidation
    function updateTokenCollateralParameters(
        uint16 currencyId,
        uint8 residualPurchaseIncentive10BPS,
        uint8 pvHaircutPercentage,
        uint8 residualPurchaseTimeBufferHours,
        uint8 cashWithholdingBuffer10BPS,
        uint8 liquidationHaircutPercentage
    ) external override onlyOwner {
        _checkValidCurrency(currencyId);
        address nTokenAddress = nTokenHandler.nTokenAddress(currencyId);
        require(nTokenAddress != address(0));

        nTokenHandler.setNTokenCollateralParameters(
            nTokenAddress,
            residualPurchaseIncentive10BPS,
            pvHaircutPercentage,
            residualPurchaseTimeBufferHours,
            cashWithholdingBuffer10BPS,
            liquidationHaircutPercentage
        );
        emit UpdateTokenCollateralParameters(currencyId);
    }

    /// @notice Updates cash group parameters
    /// @dev emit:UpdateCashGroup
    /// @param currencyId id of the currency to enable
    /// @param cashGroup new parameters for the cash group
    function updateCashGroup(uint16 currencyId, CashGroupSettings calldata cashGroup)
        external
        override
        onlyOwner
    {
        _checkValidCurrency(currencyId);
        _updateCashGroup(currencyId, cashGroup);
    }

    /// @notice Updates ETH exchange rate or related parameters
    /// @dev emit:UpdateETHRate
    /// @param currencyId id of the currency
    /// @param rateOracle new rate oracle for the asset
    /// @param rateOracle ETH to underlying rate oracle
    /// @param mustInvert if the rate from the oracle needs to be inverted
    /// @param buffer multiplier (>= 100) for negative balances when calculating free collateral
    /// @param haircut multiplier (<= 100) for positive balances when calculating free collateral
    /// @param liquidationDiscount multiplier (>= 100) for exchange rate when liquidating
    function updateETHRate(
        uint16 currencyId,
        AggregatorV2V3Interface rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) external override onlyOwner {
        _checkValidCurrency(currencyId);
        _updateETHRate(
            currencyId,
            ETHRateStorage({
                rateOracle: rateOracle,
                mustInvert: mustInvert,
                buffer: buffer,
                haircut: haircut,
                liquidationDiscount: liquidationDiscount,
                rateDecimalPlaces: 0 // This will be set inside updateETHRate
            })
        );
    }

    /// @notice Approves contracts that can call `batchTradeActionWithCallback`. These contracts can
    /// "flash loan" from Notional V2 and receive a callback before the free collateral check. Flash loans
    /// via the Notional V2 liquidity pool are not very gas efficient so this is not generally available,
    /// it can be used for migrating borrows into Notional V2 from other platforms.
    /// @dev emit:UpdateAuthorizedCallbackContract
    /// @param operator address of the contract
    /// @param approved true if the contract is authorized
    function updateAuthorizedCallbackContract(address operator, bool approved)
        external
        override
        onlyOwner
    {
        // Sanity check to ensure that operator is a contract, not an EOA
        require(Address.isContract(operator));
        authorizedCallbackContract[operator] = approved;
        emit UpdateAuthorizedCallbackContract(operator, approved);
    }

    function _updateCashGroup(uint16 currencyId, CashGroupSettings calldata cashGroup) internal {
        CashGroup.setCashGroupStorage(currencyId, cashGroup);
        emit UpdateCashGroup(currencyId);
    }

    function _updateETHRate(
        uint16 currencyId,
        ETHRateStorage memory ethRate
    ) internal {
        if (currencyId == Constants.ETH_CURRENCY_ID) {
            // ETH to ETH exchange rate is fixed at 1 and has no rate oracle
            ethRate.rateOracle = AggregatorV2V3Interface(address(0));
            ethRate.rateDecimalPlaces = Constants.ETH_DECIMAL_PLACES;
        } else {
            require(address(ethRate.rateOracle) != address(0));
            ethRate.rateDecimalPlaces = ethRate.rateOracle.decimals();
        }
        require(ethRate.buffer >= Constants.PERCENTAGE_DECIMALS);
        require(ethRate.haircut <= Constants.PERCENTAGE_DECIMALS);
        require(ethRate.liquidationDiscount > Constants.PERCENTAGE_DECIMALS);

        // Perform this check to ensure that decimal calculations don't overflow
        require(ethRate.rateDecimalPlaces <= Constants.MAX_DECIMAL_PLACES);
        mapping(uint256 => ETHRateStorage) storage store = LibStorage.getExchangeRateStorage();
        store[currencyId] = ethRate;

        emit UpdateETHRate(currencyId);
    }
}
