// SPDX-License-Identifier: GPL-v3
pragma solidity >=0.7.0;

// Inherits ERC20? or ERC4626?
interface ILeveragedVault {

    // Tells a vault to mint vault shares given the amount of cash transferred
    function mintVaultShares(
        address account,
        uint256 assetCashTransferred,
        bytes calldata data
    ) external returns (
        uint256 accountUnderlyingValue,
        uint256 vaultUnderlyingValue,
        uint256 vaultSharesMinted
    );

    // Redeems shares from the vault to asset cash.
    function redeemVaultShares(
        address account,
        uint256 vaultShares,
        bytes calldata data
    ) external returns (uint256);

    function settleVaultShares(
        uint256 vaultSharesToRedeem,
        bytes calldata data
    ) external returns (uint256 assetCashExternal);

    function isInSettlement() external view returns (bool);
    function getSharesToSettle(uint256 maturity) external view returns (
        uint256 settleableShares,
        uint256 totalSettleableShares
    );




    function assetCashValueOfShares(uint256 vaultShares) external view returns (uint256);
    function assetCashValueOf(address account) external view returns (uint256);


    /// @notice Returns the balance of an account at a maturity
    function balanceOfForMaturity(address account) external view returns (uint256);

    /// @notice Returns the total amount of vault tokens at the specified maturity
    function totalSupplyForMaturity(uint256 maturity) external view returns (uint256);

    /// @notice Returns the amount of vault tokens available to settle
    function balanceAvailableToSettle() external view returns (uint256);

    /// @notice Settles a vault and returns the amount settled and how much the vault raised
    /// @dev auth:Notional
    function settleVault(bytes calldata data) external returns (uint256 vaultSharesSettled, int256 assetCashRaised);

    /// @notice Settles a vault and returns the amount settled and how much the vault raised
    /// @dev auth:Notional
    function rollVaultPosition(
        address account,
        uint256 assetCashDeposited,
        bytes calldata data
    ) external returns (uint256 vaultSharesMinted);

    /// @notice Sells the specified amount of vault shares and returns the amount of cash raised
    /// @dev auth:Notional
    function exitVault(
        address account,
        uint256 vaultSharesToExit,
        bytes calldata data
    ) external returns (uint256 assetCashRaised);

    /// @notice Enters an account into a vault position
    /// @dev auth:Notional
    function enterVault(
        address account,
        uint256 assetCashDeposited,
        bytes calldata data
    ) external returns (uint256 vaultSharesMinted);

    /** Begin Optional Methods **/

    /// @notice [Optional] initializes a vault if required
    function initializeVault(bytes calldata data) external;

    /// @notice [Optional] deposits additional collateral for an account, must be in asset cash
    /// will be counted as part of the asset cash holding value
    function depositCollateral(address account, uint256 amount) external;

    /// @notice [Optional] withdraws additional collateral for an account
    function withdrawCollateral(address account, uint256 amount) external;

    /// @notice [Optional] Liquidates an account out of their position. This must happen entirely
    /// within the vault and will increase the account's asset cash holdings in the vault.
    function liquidate(address account, bytes memory data) external;
}