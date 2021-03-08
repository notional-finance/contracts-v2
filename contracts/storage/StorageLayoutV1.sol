// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

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
    // Liquidity fee given to LPs per trade, specified in BPS
    uint8 liquidityFeeBPS;

    /* Risk Parameters */
    // Debt buffer specified in 5 BPS increments
    uint8 debtBuffer5BPS;
    // fCash haircut specified in 5 BPS increments
    uint8 fCashHaircut5BPS;

    /* Liquidation Parameters */
    uint8 settlementPenaltyRateBPS;
    uint8 liquidityRepoDiscount;

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
 * TODO: how high can cToken exchange rates go?
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
 * free collateral actions. Total storage is 32 bytes
 */
struct AccountStorage {
    // Used to check when settlement must be trigged on an account
    uint40 nextMaturingAsset;
    // Records when the last time an account minted incentives. This must be initialized to
    // the value at the first time the account deposited capital.
    uint32 lastMintTime;
    // For lenders that never incur debt, we use this flag to skip the free collateral check.
    bool hasDebt;
    // If this account has bitmaps set, this is the corresponding currency id
    uint16 bitmapCurrencyId;
    // The initial offset for the asset array (is this sufficient?)
    uint16 assetArrayInitialOffset;
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

/**
 * @notice Storage layout for the system. Do not change this file once deployed, future storage
 * layouts must inherit this and increment the version number.
 */
contract StorageLayoutV1 {
    /* Start Non-Mapping storage slots */
    uint16 internal maxCurrencyId;
    /* End Non-Mapping storage slots */

    // Returns the exchange rate between an underlying currency and ETH for free
    // collateral purposes. Mapping is from currency id to rate storage object.
    mapping(uint => ETHRateStorage) internal underlyingToETHRateMapping;
    // Returns the exchange rate between an underlying currency and asset for trading
    // and free collateral. Mapping is from currency id to rate storage object.
    mapping(uint => AssetRateStorage) internal assetToUnderlyingRateMapping;

    /* Cash group and market storage */
    // Contains all cash group configuration information
    // currencyId => storage
    mapping(uint => CashGroupParameterStorage) internal cashGroupMapping;


    /* Account Storage */
    // Mapping account context information used to determine how its assets and currencies
    // are laid out in storage
    // address => storage
    // mapping(address => AccountStorage) internal accountContextMapping;
    // Asset arrays for accounts, if an account is using bitmaps then this may still
    // contain liquidity tokens
    // address => storage
    mapping(address => AssetStorage[]) assetArrayMapping;
    // address => currency id => maturity => ifCash value
    mapping(address => mapping(uint => mapping(uint => int))) internal ifCashMapping;

    /* Authentication Mappings */
    // This is set to the timelock contract to execute governance functions
    address internal owner;
    // This is set to the governance token address
    address internal token;

    // A blanket allowance for a spender to transfer any of an account's perpetual tokens. This would allow a user
    // to set an allowance on all perpetual tokens for a particular integrating contract system.
    // owner => spender => transferAllowance
    mapping(address => mapping(address => uint)) internal perpTokenWhitelist;
    // Individual transfer allowances for perpetual tokens used for ERC20
    // owner => spender => currencyId => transferAllowance
    mapping(address => mapping(address => mapping(uint16 => uint))) internal perpTokenTransferAllowance;
}
