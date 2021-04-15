// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

struct nTokenPortfolio {
    CashGroupParameters cashGroup;
    MarketParameters[] markets;
    PortfolioState portfolioState;
    int256 totalSupply;
    int256 cashBalance;
    uint256 lastInitializedTime;
    bytes6 parameters;
    address tokenAddress;
}

struct LiquidationFactors {
    address account;
    int256 netETHValue;
    int256 localAvailable;
    int256 collateralAvailable;
    int256 nTokenValue;
    bytes6 nTokenParameters;
    ETHRate localETHRate;
    ETHRate collateralETHRate;
    CashGroupParameters cashGroup;
    MarketParameters[] markets;
}

struct PortfolioState {
    PortfolioAsset[] storedAssets;
    PortfolioAsset[] newAssets;
    uint256 lastNewAssetIndex;
    // Holds the length of stored assets after accounting for deleted assets
    uint256 storedAssetLength;
}

/**
 * @dev Exchange rate object as stored in memory, these are cached optimistically
 * when the transaction begins. This is not the same as the object in storage.
 */

struct ETHRate {
    // The decimals (i.e. 10^rateDecimalPlaces) of the exchange rate
    int256 rateDecimals;
    // The exchange rate from base to quote (if invert is required it is already done)
    int256 rate;
    // Amount of buffer to apply to the exchange rate for negative balances.
    int256 buffer;
    // Amount of haircut to apply to the exchange rate for positive balances
    int256 haircut;
    // Liquidation discount for this currency
    int256 liquidationDiscount;
}

enum TradeActionType {
    // (uint8, uint8, uint88, uint32)
    Lend,
    // (uint8, uint8, uint88, uint32)
    Borrow,
    // (uint8, uint8, uint88, uint32, uint32)
    AddLiquidity,
    // (uint8, uint8, uint88, uint32, uint32)
    RemoveLiquidity,
    // (uint8, uint32, int88)
    PurchaseNTokenResidual,
    // (uint8, address, int88)
    SettleCashDebt
}

enum DepositActionType {
    None,
    DepositAsset,
    DepositUnderlying,
    DepositAssetAndMintNToken,
    DepositUnderlyingAndMintNToken,
    RedeemNToken
}

struct BalanceAction {
    DepositActionType actionType;
    uint16 currencyId;
    uint256 depositActionAmount;
    uint256 withdrawAmountInternalPrecision;
    bool withdrawEntireCashBalance;
    bool redeemToUnderlying;
}

struct BalanceActionWithTrades {
    DepositActionType actionType;
    uint16 currencyId;
    uint256 depositActionAmount;
    uint256 withdrawAmountInternalPrecision;
    bool withdrawEntireCashBalance;
    bool redeemToUnderlying;
    bytes32[] trades;
}

struct SettleAmount {
    uint256 currencyId;
    int256 netCashChange;
}

struct BalanceState {
    uint256 currencyId;
    // Cash balance stored in balance state at the beginning of the transaction
    int256 storedCashBalance;
    // Perpetual token balance stored at the beginning of the transaction
    int256 storedPerpetualTokenBalance;
    // The net cash change as a result of asset settlement or trading
    int256 netCashChange;
    // Net asset transfers into or out of the account
    int256 netAssetTransferInternalPrecision;
    // Net perpetual token transfers into or out of the account
    int256 netPerpetualTokenTransfer;
    // Net perpetual token supply change from minting or redeeming
    int256 netPerpetualTokenSupplyChange;
    // The last time incentives were claimed for this currency
    uint256 lastIncentiveClaim;
}

/// @dev Asset rate object as stored in memory, these are cached optimistically
/// when the transaction begins. This is not the same as the object in storage.
struct AssetRateParameters {
    // Address of the asset rate oracle
    address rateOracle;
    // The exchange rate from base to quote (if invert is required it is already done)
    int256 rate;
    // The decimals of the underlying, the rate converts to the underlying decimals
    int256 underlyingDecimals;
}

/// @dev Cash group when loaded into memory
struct CashGroupParameters {
    uint256 currencyId;
    uint256 maxMarketIndex;
    AssetRateParameters assetRate;
    bytes32 data;
}

enum AssetStorageState {NoChange, Update, Delete}

struct PortfolioAsset {
    // Asset currency id
    uint256 currencyId;
    uint256 maturity;
    // Asset type, fCash or liquidity token.
    uint256 assetType;
    // fCash amount or liquidity token amount
    int256 notional;
    uint256 storageSlot;
    // The state of the asset for when it is written to storage
    AssetStorageState storageState;
}

/**
 * Market object as represented in memory
 */
struct MarketParameters {
    bytes32 storageSlot;
    uint256 maturity;
    // Total amount of fCash available for purchase in the market.
    int256 totalfCash;
    // Total amount of cash available for purchase in the market.
    int256 totalCurrentCash;
    // Total amount of liquidity tokens (representing a claim on liquidity) in the market.
    int256 totalLiquidity;
    // This is the implied rate that we use to smooth the anchor rate between trades.
    uint256 lastImpliedRate;
    // This is the oracle rate used to value fCash and prevent flash loan attacks
    uint256 oracleRate;
    // This is the timestamp of the previous trade
    uint256 previousTradeTime;
    // Used to determine if the market has been updated
    bytes1 storageState;
}

struct SettlementMarket {
    bytes32 storageSlot;
    // Total amount of fCash available for purchase in the market.
    int256 totalfCash;
    // Total amount of cash available for purchase in the market.
    int256 totalCurrentCash;
    // Total amount of liquidity tokens (representing a claim on liquidity) in the market.
    int256 totalLiquidity;
    // Un parsed market data used for storage
    bytes32 data;
}

/// @notice Used in SettleAssets for calculating bitmap shifts
struct SplitBitmap {
    bytes32 dayBits;
    bytes32 weekBits;
    bytes32 monthBits;
    bytes32 quarterBits;
}

struct TokenStorage {
    address tokenAddress;
    bool hasTransferFee;
    TokenType tokenType;
}

enum TokenType {UnderlyingToken, cToken, cETH, Ether, NonMintable}

struct Token {
    address tokenAddress;
    bool hasTransferFee;
    int256 decimals;
    TokenType tokenType;
}

/**
 * @dev Exchange rate object as it is represented in storage, total storage is 25 bytes.
 */
struct ETHRateStorage {
    // Address of the rate oracle
    address rateOracle;
    // The decimal places of precision that the rate oracle uses
    uint8 rateDecimalPlaces;
    // True of the exchange rate must be inverted
    bool mustInvert;
    // NOTE: both of these governance values are set with BUFFER_DECIMALS precision
    // Amount of buffer to apply to the exchange rate for negative balances.
    uint8 buffer;
    // Amount of haircut to apply to the exchange rate for positive balances
    uint8 haircut;
    // Liquidation discount in percentage point terms, 106 means a 6% discount
    uint8 liquidationDiscount;
}

/**
 * @dev Asset rate object as it is represented in storage, total storage is 21 bytes.
 */
struct AssetRateStorage {
    // Address of the rate oracle
    address rateOracle;
    // The decimal places of the underlying asset
    uint8 underlyingDecimalPlaces;
}

/**
 * @dev Governance parameters for a cash group, total storage is 7 bytes + 9 bytes
 * or liquidity token haircuts and 9 bytes for rate scalars, total of 25 bytes
 */
struct CashGroupParameterStorage {
    /* Market Parameters */
    // Index of the AMMs on chain that will be made available. Idiosyncratic fCash
    // that is less than the longest AMM will be tradable.
    uint8 maxMarketIndex;
    // Time window in minutes that the rate oracle will be averaged over
    uint8 rateOracleTimeWindowMin;
    // Total fees per trade, specified in BPS
    uint8 totalFeeBPS;
    // Share of the fees given to the protocol, denominated in percentage
    uint8 reserveFeeShare;
    /* Risk Parameters */
    // Debt buffer specified in 5 BPS increments
    uint8 debtBuffer5BPS;
    // fCash haircut specified in 5 BPS increments
    uint8 fCashHaircut5BPS;
    /* Liquidation Parameters */
    uint8 settlementPenaltyRateBPS;
    uint8 liquidationfCashHaircut5BPS;
    // Liquidity token haircut applied to cash claims, specified as a percentage between 0 and 100
    uint8[] liquidityTokenHaircuts;
    // Rate scalar used to determine the slippage of the market
    uint8[] rateScalars;
}

/**
 * @dev As long as we're not adding or removing liquidity, we only need to read
 * these particular parameters. uint80 ~ 1.2e24. Rate precision on markets is set
 * to 9 decimal places so we will never accrue interest at higher precision. All
 * fCash and liquidity tokens can be safely denominated at 9 decimal places and then
 * converted to their appropriate decimal precision when they are settled. uint80
 * allows each market to have a quadrillion in fCash which seems reasonable.
 *
 * Total storage: 32 bytes
struct MarketStorage {
    uint80 totalfCash;
    uint80 totalCurrentCash;
    uint32 lastImpliedRate;
    uint32 oracleRate;
    // Maturities are represented as uint40 but trade times are uint32 as this will
    // continue to work until year 2106.
    uint32 previousTradeTime;
}
 */

/**
 * @dev Holds account level context information used to determine settlement and
 * free collateral actions. Total storage is 28 bytes
 */
struct AccountContext {
    // Used to check when settlement must be trigged on an account
    uint40 nextSettleTime;
    // For lenders that never incur debt, we use this flag to skip the free collateral check.
    bytes1 hasDebt;
    // Length of the account's asset array
    uint8 assetArrayLength;
    // If this account has bitmaps set, this is the corresponding currency id
    uint16 bitmapCurrencyId;
    // 9 total active currencies possible (2 bytes each)
    bytes18 activeCurrencies;
}

/**
 * @dev Asset stored in the asset array, total storage is 19 bytes.
 */
struct AssetStorage {
    // ID of the cash group this asset is contained in
    uint16 currencyId;
    // Timestamp of the maturity in seconds, this works up to year 3800 or something. uint32
    // only supports maturities up to 2106 which won't allow for 80+ year fCash :).
    uint40 maturity;
    // Asset enum type
    uint8 assetType;
    // Positive or negative notional amount
    int88 notional;
}
