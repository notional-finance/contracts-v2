// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

/**
 * @dev Total storage is 8 bytes
 */
struct CashGroupParameterStorage {
    /* Market Parameters */
    // Time window in minutes that the rate oracle will be averaged over
    uint8 rateOracleTimeWindowMin;
    // Liquidity fee given to LPs per trade, specified in BPS
    uint8 liquidityFeeBPS;
    // Rate scalar used to determine the slippage of the market
    uint16 rateScalar;
    // Index of the AMMs on chain that will be made available. Idiosyncratic fCash
    // that is less than the longest AMM will be tradable.
    uint8 maxMarketIndex;

    /* Risk Parameters */
    // Liquidity token haircut applied to cash claims, specified as a percentage between 0 and 100
    uint8 liquidityTokenHaircut;
    // Debt buffer specified in BPS
    uint8 debtBufferBPS;
    // fCash haircut specified in BPS
    uint8 fCashHaircutBPS;

    /* Liquidation Parameters */
    // uint8 settlementPenaltyRateBPS;
    // uint8 liquidityRepoDiscount;
    // uint8 liquidationDiscount;
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
 */
struct MarketStorage {
    uint80 totalfCash;
    uint80 totalCurrentCash;
    uint32 lastImpliedRate;
    uint32 oracleRate;
    // Maturities are represented as uint40 but trade times are uint32 as this will
    // continue to work until year 2106.
    uint32 previousTradeTime;
}

/**
 * @dev Holds account level context information used to determine settlement and
 * free collateral actions. Total storage is 6 bytes + (maxCurrencyId / 8 + 1)
 *
 * WARNING: because activeCurrencies is a dynamically sized byte array we cannot
 * add more storage slots into this struct.
 */
struct AccountStorage {
    // Used to check when settlement must be trigged on an account
    uint40 nextMaturingAsset;
    // For lenders that never incur debt, we use this flag to skip the free
    // collateral check.
    bool hasDebt;
    // This is a tightly packed bitmap of the currenices that the account has a non
    // zero balance in. The highest order (left most) bit will refer to currency id=1
    // (currency id = 0 is unused) and so forth. This allows us to limit the number of
    // storage reads while expanding the number of currencies we support.
    bytes activeCurrencies;
}

/**
 * @dev Asset stored in the asset array, total storage is 18 bytes.
 */
struct AssetStorage {
    // ID of the cash group this asset is contained in
    uint8 cashGroupId;
    // Asset enum type
    uint8 assetType;
    // Timestamp of the maturity in seconds, this works up to year 3800 or something. uint32
    // only supports maturities up to 2106 which won't allow for 80+ year fCash :).
    uint40 maturity;
    // Positive or negative notional amount
    int88 notional;
}

/**
 * @notice Storage layout for the system. Do not change this file once deployed, future storage
 * layouts must inherit this and increment the version number.
 */
contract StorageLayoutV1 {
    uint8 public constant storageLayoutVersion = 1;
    /* Start Non-Mapping storage slots */
    uint16 maxCurrencyId;
    uint16 maxCashGroupId;
    /* End Non-Mapping storage slots */

    // Mapping of whitelisted currencies from currency id to object struct
    // mapping(uint => CurrencyStorage) currencies;

    /* Cash group and market storage */
    // Contains all cash group configuration information
    // cashGroupId => storage
    mapping(uint => CashGroupParameterStorage) cashGroupMapping;
    // Contains current market state information
    // cashGroupId => maturity => storage
    mapping(uint => mapping(uint => MarketStorage)) marketStateMapping;
    // Keep total liquidity in a separate storage slot because it is not referenced
    // on every trade, only when adding or removing liquidity
    // cashGroupId => maturity => totalLiquditiy
    mapping(uint => mapping(uint => uint80)) marketTotalLiquidityMapping;


    /* Account Storage */
    // Mapping account context information used to determine how its assets and currencies
    // are laid out in storage
    // address => storage
    mapping(address => AccountStorage) accountContextMapping;
    // Asset arrays for accounts, if an account is using bitmaps then this may still
    // contain liquidity tokens
    // address => storage
    mapping(address => AssetStorage[]) assetArrayMapping;
    // address => cash group => bitmap
    mapping(address => mapping(uint => bytes)) assetBitmapMapping;
    // address => cash group => maturity => ifCash value
    mapping(address => mapping(uint => mapping(uint => int))) ifCashMapping;
    // address => token address => net balance
    mapping(address => mapping(address => int)) accountBalanceMapping;

    // TODO: authorization mappings
    // TODO: function mappings
}