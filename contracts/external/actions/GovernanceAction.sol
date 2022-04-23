// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../internal/valuation/ExchangeRate.sol";
import "../../internal/markets/CashGroup.sol";
import "../../internal/nToken/nTokenHandler.sol";
import "../../internal/nToken/nTokenSupply.sol";
import "../../internal/balances/TokenHandler.sol";
import "../../global/StorageLayoutV2.sol";
import "../../global/LibStorage.sol";
import "../../global/Types.sol";
import "../../proxy/utils/UUPSUpgradeable.sol";
import "../adapters/nTokenERC20Proxy.sol";
import "../../../interfaces/notional/IRewarder.sol";
import "../../../interfaces/notional/AssetRateAdapter.sol";
import "../../../interfaces/chainlink/AggregatorV2V3Interface.sol";
import "../../../interfaces/notional/NotionalGovernance.sol";
import "../../../interfaces/notional/nTokenERC20.sol";
import "./ActionGuards.sol";
import "@openzeppelin/contracts/utils/Address.sol";

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
    /// @param assetToken the token parameters for the asset token
    /// @param underlyingToken the underlying token (if asset token is an interest bearing wrapper)
    /// @param rateOracle ETH to underlying rate oracle
    /// @param mustInvert if the rate from the oracle needs to be inverted
    /// @param buffer multiplier (>= 100) for negative balances when calculating free collateral
    /// @param haircut multiplier (<= 100) for positive balances when calculating free collateral
    /// @param liquidationDiscount multiplier (>= 100) for exchange rate when liquidating
    /// @return the new currency id
    function listCurrency(
        TokenStorage calldata assetToken,
        TokenStorage calldata underlyingToken,
        AggregatorV2V3Interface rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) external override onlyOwner returns (uint16) {
        uint16 currencyId = maxCurrencyId + 1;
        // Set the new max currency id
        maxCurrencyId = currencyId;
        require(currencyId <= Constants.MAX_CURRENCIES, "G: max currency overflow");
        // NOTE: this allows multiple asset tokens that have the same underlying. That is ok from a protocol
        // perspective. For example, we may choose list cDAI, yDAI and aDAI as asset currencies and each can
        // trade as different forms of fDAI.
        require(
            tokenAddressToCurrencyId[assetToken.tokenAddress] == 0,
            "G: duplicate token listing"
        );
        tokenAddressToCurrencyId[assetToken.tokenAddress] = currencyId;

        // Set the underlying first because the asset token may set an approval using the underlying
        if (
            underlyingToken.tokenAddress != address(0) ||
            // Ether has a token address of zero
            underlyingToken.tokenType == TokenType.Ether
        ) {
            // NOTE: set token will enforce the restriction that Ether can only be set once as the zero
            // address. This sets the underlying token
            TokenHandler.setToken(currencyId, true, underlyingToken);
        }

        // This sets the asset token
        TokenHandler.setToken(currencyId, false, assetToken);

        _updateETHRate(currencyId, rateOracle, mustInvert, buffer, haircut, liquidationDiscount);

        emit ListCurrency(currencyId);

        return currencyId;
    }

    /// @notice Sets a maximum balance on a given currency. Max collateral balance cannot be set on a
    /// currency that is actively used in trading, this may cause issues with liquidation. Also, max
    /// collateral balance is only set on asset tokens (not underlying tokens) because underlying tokens
    /// are not held as contract balances.
    /// @dev emit:UpdateMaxCollateralBalance
    /// @param currencyId id of the currency to set the max collateral balance on
    /// @param maxCollateralBalanceInternalPrecision amount of collateral balance that can be held
    /// in this currency denominated in internal token precision
    function updateMaxCollateralBalance(
        uint16 currencyId,
        uint72 maxCollateralBalanceInternalPrecision
    ) external override onlyOwner {
        _checkValidCurrency(currencyId);
        // Cannot turn on max collateral balance for a currency that is trading
        if (maxCollateralBalanceInternalPrecision > 0) require(CashGroup.getMaxMarketIndex(currencyId) == 0);
        TokenHandler.setMaxCollateralBalance(currencyId, maxCollateralBalanceInternalPrecision);
        emit UpdateMaxCollateralBalance(currencyId, maxCollateralBalanceInternalPrecision);
    }

    /// @notice Enables a cash group on a given currency so that it can have lend and borrow markets. Will
    /// also deploy an nToken contract so that markets can be initialized.
    /// @dev emit:UpdateCashGroup emit:UpdateAssetRate emit:DeployNToken
    /// @param currencyId id of the currency to enable
    /// @param assetRateOracle address of the rate oracle for converting interest bearing assets to
    /// underlying values
    /// @param cashGroup parameters for the cash group
    /// @param underlyingName underlying token name for seeding nToken name
    /// @param underlyingSymbol underlying token symbol for seeding nToken symbol (i.e. nDAI)
    function enableCashGroup(
        uint16 currencyId,
        AssetRateAdapter assetRateOracle,
        CashGroupSettings calldata cashGroup,
        string calldata underlyingName,
        string calldata underlyingSymbol
    ) external override onlyOwner {
        _checkValidCurrency(currencyId);
        {
            // Cannot enable fCash trading on a token with a max collateral balance
            Token memory assetToken = TokenHandler.getAssetToken(currencyId);
            Token memory underlyingToken = TokenHandler.getUnderlyingToken(currencyId);
            require(
                assetToken.maxCollateralBalance == 0 &&
                underlyingToken.maxCollateralBalance == 0
            ); // dev: cannot enable trading, collateral cap
        }

        _updateCashGroup(currencyId, cashGroup);
        _updateAssetRate(currencyId, assetRateOracle);

        // Creates the nToken erc20 proxy that routes back to the main contract
        nTokenERC20Proxy proxy = new nTokenERC20Proxy(
            nTokenERC20(address(this)),
            currencyId,
            underlyingName,
            underlyingSymbol
        );
        nTokenHandler.setNTokenAddress(currencyId, address(proxy));
        emit DeployNToken(currencyId, address(proxy));
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

    /// @notice Updates the emission rate of incentives for a given currency
    /// @dev emit:UpdateIncentiveEmissionRate
    /// @param currencyId the currency id that the nToken references
    /// @param newEmissionRate Target total incentives to emit for an nToken over an entire year
    /// denominated in WHOLE TOKENS (i.e. setting this to 1 means 1e8 tokens). The rate will not be
    /// exact due to multiplier effects and fluctuating token supply.
    function updateIncentiveEmissionRate(uint16 currencyId, uint32 newEmissionRate)
        external
        override
        onlyOwner
    {
        _checkValidCurrency(currencyId);
        address nTokenAddress = nTokenHandler.nTokenAddress(currencyId);
        require(nTokenAddress != address(0), "Invalid currency");
        // Sanity check that emissions rate is not specified in 1e8 terms.
        require(newEmissionRate < Constants.INTERNAL_TOKEN_PRECISION, "Invalid rate");

        nTokenSupply.setIncentiveEmissionRate(nTokenAddress, newEmissionRate, block.timestamp);
        emit UpdateIncentiveEmissionRate(currencyId, newEmissionRate);
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
        require(nTokenAddress != address(0), "Invalid currency");

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

    /// @notice Updates asset rate oracle
    /// @dev emit:UpdateAssetRate
    /// @param currencyId id of the currency
    /// @param rateOracle new rate oracle for the asset
    function updateAssetRate(uint16 currencyId, AssetRateAdapter rateOracle) external override onlyOwner {
        _checkValidCurrency(currencyId);
        _updateAssetRate(currencyId, rateOracle);
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
        _updateETHRate(currencyId, rateOracle, mustInvert, buffer, haircut, liquidationDiscount);
    }

    /// @notice Sets a global transfer operator that can do authenticated ERC1155 transfers. This enables
    /// OTC trading or other use cases such as layer 2 authenticated transfers.
    /// @dev emit:UpdateGlobalTransferOperator
    /// @param operator address of the operator
    /// @param approved true if the operator is allowed to transfer globally
    function updateGlobalTransferOperator(address operator, bool approved)
        external
        override
        onlyOwner
    {
        // Sanity check to ensure that operator is a contract, not an EOA
        require(Address.isContract(operator), "Operator must be a contract");

        globalTransferOperator[operator] = approved;
        emit UpdateGlobalTransferOperator(operator, approved);
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
        require(Address.isContract(operator), "Operator must be a contract");
        authorizedCallbackContract[operator] = approved;
        emit UpdateAuthorizedCallbackContract(operator, approved);
    }

    /// @notice Sets a secondary incentive rewarder for a currency. This contract will
    /// be called whenever an nToken balance changes and allows a secondary contract to
    /// mint incentives to the account. This will override any previous rewarder, if set.
    /// Will have no effect if there is no nToken corresponding to the currency id.
    /// @dev emit:UpdateSecondaryIncentiveRewarder
    /// @param currencyId currency id of the nToken
    /// @param rewarder rewarder contract
    function setSecondaryIncentiveRewarder(uint16 currencyId, IRewarder rewarder)
        external
        override
        onlyOwner
    {
        _checkValidCurrency(currencyId);
        require(Address.isContract(address(rewarder)), "Rewarder must be a contract");
        nTokenHandler.setSecondaryRewarder(currencyId, rewarder);
        emit UpdateSecondaryIncentiveRewarder(currencyId, address(rewarder));
    }

    /// @notice Updates the lending pool address used by AaveHandler
    /// @dev emit:UpdateLendingPool
    /// @param pool lending pool address
    function setLendingPool(ILendingPool pool) external override onlyOwner {
        LendingPoolStorage storage store = LibStorage.getLendingPool();
        require(address(pool) != address(0) && address(store.lendingPool) == address(0), "Invalid lending pool");
        store.lendingPool = pool;
        emit UpdateLendingPool(address(pool));
    }

    function _updateCashGroup(uint16 currencyId, CashGroupSettings calldata cashGroup) internal {
        CashGroup.setCashGroupStorage(currencyId, cashGroup);
        emit UpdateCashGroup(currencyId);
    }

    function _updateAssetRate(uint16 currencyId, AssetRateAdapter rateOracle) internal {
        // If rate oracle refers to address zero then do not apply any updates here, this means
        // that a token is non mintable.
        Token memory assetToken = TokenHandler.getAssetToken(currencyId);
        if (address(rateOracle) == address(0)) {
            // Sanity check that unset rate oracles are only for non mintable tokens
            require(assetToken.tokenType == TokenType.NonMintable, "G: invalid asset rate");
        } else {
            // Sanity check that the rate oracle refers to the proper asset token
            address token = AssetRateAdapter(rateOracle).token();
            require(assetToken.tokenAddress == token, "G: invalid rate oracle");

            uint8 underlyingDecimals;
            if (currencyId == Constants.ETH_CURRENCY_ID) {
                // If currencyId is one then this is referring to cETH and there is no underlying() to call
                underlyingDecimals = Constants.ETH_DECIMAL_PLACES;
            } else {
                address underlyingTokenAddress = AssetRateAdapter(rateOracle).underlying();
                Token memory underlyingToken = TokenHandler.getUnderlyingToken(currencyId);
                // Sanity check to ensure that the asset rate adapter refers to the correct underlying
                require(underlyingTokenAddress == underlyingToken.tokenAddress, "G: invalid adapter");
                underlyingDecimals = ERC20(underlyingTokenAddress).decimals();
            }

            // Perform this check to ensure that decimal calculations don't overflow
            require(underlyingDecimals <= Constants.MAX_DECIMAL_PLACES);
            mapping(uint256 => AssetRateStorage) storage store = LibStorage.getAssetRateStorage();
            store[currencyId] = AssetRateStorage({
                rateOracle: rateOracle,
                underlyingDecimalPlaces: underlyingDecimals
            });

            emit UpdateAssetRate(currencyId);
        }
    }

    function _updateETHRate(
        uint16 currencyId,
        AggregatorV2V3Interface rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) internal {
        uint8 rateDecimalPlaces;
        if (currencyId == Constants.ETH_CURRENCY_ID) {
            // ETH to ETH exchange rate is fixed at 1 and has no rate oracle
            rateOracle = AggregatorV2V3Interface(address(0));
            rateDecimalPlaces = Constants.ETH_DECIMAL_PLACES;
        } else {
            require(address(rateOracle) != address(0), "G: zero rate oracle address");
            rateDecimalPlaces = rateOracle.decimals();
        }
        require(buffer >= Constants.PERCENTAGE_DECIMALS, "G: buffer must be gte decimals");
        require(haircut <= Constants.PERCENTAGE_DECIMALS, "G: buffer must be lte decimals");
        require(
            liquidationDiscount > Constants.PERCENTAGE_DECIMALS,
            "G: discount must be gt decimals"
        );

        // Perform this check to ensure that decimal calculations don't overflow
        require(rateDecimalPlaces <= Constants.MAX_DECIMAL_PLACES);
        mapping(uint256 => ETHRateStorage) storage store = LibStorage.getExchangeRateStorage();
        store[currencyId] = ETHRateStorage({
            rateOracle: rateOracle,
            rateDecimalPlaces: rateDecimalPlaces,
            mustInvert: mustInvert,
            buffer: buffer,
            haircut: haircut,
            liquidationDiscount: liquidationDiscount
        });

        emit UpdateETHRate(currencyId);
    }
}
