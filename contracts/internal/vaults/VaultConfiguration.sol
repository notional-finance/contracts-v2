// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

library VaultFlags {
    uint16 internal constant ENABLED            = 1 << 0;
    uint16 internal constant ALLOW_REENTER      = 1 << 1;
    uint16 internal constant IS_INSURED         = 1 << 2;
    uint16 internal constant CAN_INITIALIZE     = 1 << 3;
    uint16 internal constant ACCEPTS_COLLATERAL = 1 << 4;
}

library VaultConfiguration {


    struct VaultConfigStorage {
        // Vault Flags (positions 0 to 15 starting from right):
        // 0: enabled - true if vault is enabled
        // 1: allowReenter - true if vault allows reentering before term expiration
        // 2: isInsured - true if vault is covered by nToken insurance
        // 3: canInitialize - true if vault can be initialized
        // 4: acceptsCollateral - true if vault can accept collateral
        uint16 flags;

        // Each vault only borrows in a single currency
        uint16 borrowCurrencyId;
        // Absolute maximum vault size (fCash overflows at int88)
        // NOTE: we can reduce this to uint48 to allow for a 281 trillion token vault (in whole 8 decimals)
        int88 maxBorrowSize;
        // A value in 1e8 scale that represents the relative risk of this vault. Governs how large the
        // vault can get relative to staked nToken insurance
        uint32 riskFactor;
        // The number of days of each vault term (this is sufficient for 20 year vaults)
        uint16 termLengthInDays;
        // Allows up to a 12.75% fee
        uint8 nTokenFee5BPS;
        // Can be anywhere from 0% to 255% additional collateral required on the principal borrowed
        uint8 collateralBufferPercent;
        // Specified in whole tokens in 1e8 precision, allows a 4.2 billion min borrow size
        uint32 minBorrowSize;

        // 48 bytes left
    }

    struct VaultConfig {
        uint16 flags;
        uint16 borrowCurrencyId;
        int256 maxBorrowSize;
        uint256 riskFactor;
        uint256 termLength;
    }

    function getVault(
        address vaultAddress
    ) internal view returns (VaultConfig memory vaultConfig) {
        // get vault config

    }

    function setVaultConfiguration(
        VaultConfig memory vaultConfig,
        address vaultAddress
    ) internal {
        // set vault config

    }

    function setVaultStatus(
        address vaultAddress,
        bool enabled
    ) internal {

    }

    /**
     * @notice Returns that status of a given flagID from VaultFlags
     */
    function getFlag(
        VaultConfig memory vaultConfig
        uint16 flagID
    ) internal pure returns (bool) {
        return (vaultConfig.flags & flagID) == flagID;
    }

    function getCurrentMaturity(
        VaultConfig memory vaultConfig,
        uint256 blockTime
    ) internal pure returns (uint256) {

    }


    /**
     * @notice Some vaults may have a settlement period at the end of their term (prior to maturity),
     * when they cannot be entered and they are in the process of unwinding positions. Existing vault
     * positions may be "rolled" into the next term during this time period.
     */
    function isInSettlement(
        VaultConfig memory vaultConfig,
        uint256 blockTime
    ) internal pure returns (bool) {
        // TODO: should this be on the vault?
        return blockTime 

    }

    /**
     * @notice Allows an account to enter a vault term. Will do the following:
     *  - Check that the account is not in the vault in a different term
     *  - Check that the amount of fCash can be borrowed based on vault parameters
     *  - Borrow fCash from the vault's active market term
     *  - Calculate the netUnderlying = convertToUnderlying(netAssetCash)
     *  - Calculate the amount of collateral required (fCash - netUnderlying) + collateralBuffer * netUnderlying
     *  - Pay the required fee to the nToken
     *  - Calculate the assetCashExternal to the vault (netAssetCash - fee)
     *  - Store the account's fCash and collateral position
     *  - Store the vault's total fCash position
     */
    function _enterVault(
        VaultConfig memory vaultConfig,
        address vault,
        address account,
        uint256 fCash,
        uint256 maxBorrowRate,
        uint256 blockTime
    ) private returns (
        int256 assetCashCollateralRequired,
        int256 assetCashToVault
    ) {
        bytes32[] memory trades = new bytes[](1);
        trades[0] = vaultConfig.encodeBorrowTrade(fCash, maxBorrowRate);
        // Executes a trade and returns the net borrow position, if the vault's total
        // borrow position is checked inside here to see if it is acceptable.
        int256 netAssetCash = vaultConfig.executeTrades(trades);
        require(netAssetCash > 0);

        // TODO: transfer in collateral from account for interest payment
        int256 collateralRequired;
        // TODO: need to mark the account's fCash position and collateral held


        // Calculate the fee and pay it to staked nToken holders
        int256 nTokenFee = vaultConfig.getNTokenFee(netAssetCash);
        nTokenStaked.payFeeToStakedNToken(vaultConfig.borrowCurrencyId, nTokenFee, blockTime);
    }

    function enterCurrentVault(
        VaultConfig memory vaultConfig,
        address vault,
        address account,
        uint256 fCash,
        uint256 maxBorrowRate,
        uint256 blockTime
    ) internal returns (
        int256 assetCashCollateralRequired,
        int256 assetCashToVault
    ) {

    }

    function enterNextVault(
        VaultConfig memory vaultConfig,
        address vault,
        address account,
        uint256 fCash,
        uint256 maxBorrowRate,
        uint256 blockTime
    ) internal returns (
        int256 assetCashCollateralRequired,
        int256 assetCashToVault
    ) {
    }

    /**
     * @notice Allows an account to exit a vault term by lending their fCash
     * - Check that fCash is less than or equal to account's position
     * - Either:
     *      Lend fCash on the market, calculate the cost to do so
     *      Deposit cash on the market, calculate the cost to do so
     * - Net off the cost to lend fCash with the account's collateral position
     * - Return the cost to exit the position (normally negative but theoretically can
     *   be positive if holding a collateral buffer > 100%)
     * - Clear the account's fCash and collateral position
     */
    function exitVault(
        VaultConfig memory vaultConfig,
        address account,
        uint256 fCash,
        uint256 minLendRate,
        uint256 blockTime
    ) internal returns (
        int256 assetCashCostToExit
    ) {
        int256 netAssetCashInternal;
        if (minLendRate == type(uint32).max) {
            // If minLendRate is set to the max, this signifies that we should just avoid
            // lending and just have the account deposit the required cash. This can be
            // more efficient during scenarios where lending isn't worth the gas cost or
            // when interest rates are extremely low.
            netAssetCashInternal = ar.convertFromUnderlying(fCash);
        } else {
            bytes32[] memory trades = new bytes[](1);
            trades[0] = vaultConfig.encodeLendTrade(fCash, minLendRate);
            // Executes a trade and returns the net borrow position
            netAssetCashInternal = vaultConfig.executeTrades(trades);
        }
        require(netAssetCashInternal < 0);

    }
}