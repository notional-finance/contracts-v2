// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.11;
pragma abicoder v2;

import "../../../interfaces/notional/IStrategyVault.sol";
import "../../../interfaces/notional/NotionalProxy.sol";
import "@openzeppelin-4.6/contracts/token/ERC20/ERC20.sol";

abstract contract BaseStrategyVault is ERC20 {
    
    struct MaturityPool {
        uint128 totalVaultShares;
        uint128 totalCashTokens;
        uint128 totalStrategyTokens;
        // 128 bytes left
    }

    /// @notice A mapping between vault shares and a maturity
    mapping(uint256 => MaturityPool) public vaultMaturityPools;

    uint16 internal immutable BORROW_CURRENCY_ID;
    // IERC20 public immutable ASSET_TOKEN;
    // IERC20 public immutable UNDERLYING_TOKEN;
    uint256 constant internal INTERNAL_TOKEN_PRECISION = 1e8;
    uint8 immutable private _decimals;
    NotionalProxy public immutable NOTIONAL;
    uint256 immutable internal UNDERLYING_TOKEN_PRECISION;

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        NotionalProxy notional_,
        uint16 borrowCurrencyId_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
        NOTIONAL = notional_;
        BORROW_CURRENCY_ID = borrowCurrencyId_;

        (
            /* Token memory assetToken */,
            Token memory underlyingToken,
            /* ETHRate memory ethRate */,
            /* AssetRateParameters memory assetRate */
        ) = notional_.getCurrencyAndRates(borrowCurrencyId_);

        require(underlyingToken.decimals > 0);
        UNDERLYING_TOKEN_PRECISION = uint256(underlyingToken.decimals);
    }

    // TODO: asset token mint / redeem methods

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (from != address(0) && to != address(0)) {
            // TODO: check fungibility between the maturities here.
        }
    }

    function mintVaultShares(
        address account,
        uint256 newMaturity,
        uint256 oldMaturity,
        uint256 assetCashTransferred,
        int256 assetCashExchangeRate,
        bytes calldata data
    ) external returns (
        int256 accountUnderlyingInternalValue,
        uint256 vaultSharesMinted
    ) {
        // Only Notional is authorized to mint vault shares
        require(msg.sender == address(NOTIONAL));

        uint256 previousMaturityCashTokens;
        uint256 strategyTokensToDeposit;
        if (oldMaturity != 0 && newMaturity != oldMaturity) {
            // If the account is moving maturities, then withdraw everything that remains from the old
            // maturity and transfer it to the new one.
            MaturityPool memory oldMaturityPool = vaultMaturityPools[oldMaturity];
            (
                previousMaturityCashTokens,
                strategyTokensToDeposit
            ) = _redeemVaultSharesInMaturity(account, oldMaturity, balanceOf(account), oldMaturityPool);
        }

        MaturityPool memory maturityPool = vaultMaturityPools[newMaturity];

        // When minting, we need to maintain the ratio of tokens to asset cash (if there is any). This ensures
        // that redeeming vault shares for each account results in the same proportion of each token.
        uint256 assetCashToUse = previousMaturityCashTokens + assetCashTransferred;
        uint256 cashToDeposit;
        if (maturityPool.totalCashTokens > 0) {
            uint256 totalMaturityValueInAssetCash = 
                _convertToCashTokens(_convertStrategyToUnderlying(maturityPool.totalStrategyTokens), assetCashExchangeRate) +
                maturityPool.totalCashTokens;

            uint256 totalValueOfDeposits = 
                _convertToCashTokens(_convertStrategyToUnderlying(strategyTokensToDeposit), assetCashExchangeRate) +
                assetCashToUse;

            cashToDeposit = (totalValueOfDeposits * maturityPool.totalCashTokens) / totalMaturityValueInAssetCash;

            // It's possible that an account cannot roll into a new maturity when the new maturity is holding
            // cash tokens. It would need to redeem additional strategy tokens in order to have sufficient cash
            // to enter the new maturity. This is will only happen for accounts that are rolling maturities with
            // active strategy token positions (not entering maturities for the first time).
            require(cashToDeposit <= assetCashToUse, "Insufficient cash");
        }
        uint256 strategyTokensMinted = _mintStrategyTokens(account, newMaturity, assetCashToUse, data);

        // Return values
        vaultSharesMinted = _mintVaultSharesInMaturity(account, newMaturity, cashToDeposit, strategyTokensMinted, maturityPool);
        accountUnderlyingInternalValue = _convertUnderlyingToInternalPrecision(
            _getAccountValue(maturityPool, balanceOf(account), assetCashExchangeRate)
        );
    }

    /**
     * @notice Only callable by Notional, will initiate redemption of vault shares.
     * @param account the account to redeem vault shares from
     * @param vaultSharesToRedeem the number of vault shares to redeem
     * @param maturity the maturity that the account is in
     * @return accountUnderlyingInternalValue the value (in underlying terms) of the account's vault shares 
     * (i.e. strategy tokens + cash tokens)
     * @return cashToTransfer the amount of asset cash Notional should transfer from this vault
     */
    function redeemVaultShares(
        address account,
        uint256 vaultSharesToRedeem,
        uint256 maturity,
        int256 assetCashExchangeRate,
        bytes calldata data
    ) external returns (
        int256 accountUnderlyingInternalValue,
        uint256 cashToTransfer
    ) {
        // Only allow NOTIONAL to call this method
        require(msg.sender == address(NOTIONAL));
        MaturityPool memory maturityPool = vaultMaturityPools[maturity];
        (
            uint256 cashTokensWithdrawn,
            uint256 strategyTokensWithdrawn
        ) = _redeemVaultSharesInMaturity(account, maturity, vaultSharesToRedeem, maturityPool);

        // Return values
        cashToTransfer = cashTokensWithdrawn + _redeemStrategyTokens(account, maturity, strategyTokensWithdrawn, data);
        accountUnderlyingInternalValue = _convertUnderlyingToInternalPrecision(
            _getAccountValue(maturityPool, balanceOf(account), assetCashExchangeRate)
        );
    }

    /**
     * @notice Mints vault shares within a given maturity and updates account balances
     */
    function _mintVaultSharesInMaturity(
        address account,
        uint256 maturity,
        uint256 cashTokensDeposited,
        uint256 strategyTokensDeposited,
        MaturityPool memory maturityPool
    ) private returns (uint256 vaultSharesMinted) {
        if (maturityPool.totalVaultShares == 0) {
            vaultSharesMinted = strategyTokensDeposited;
        } else {
            vaultSharesMinted = (strategyTokensDeposited * maturityPool.totalVaultShares) / maturityPool.totalStrategyTokens;
        }

        // Update the vault maturity in storage
        maturityPool.totalCashTokens += _safeUint128(cashTokensDeposited);
        maturityPool.totalStrategyTokens += _safeUint128(strategyTokensDeposited);
        maturityPool.totalVaultShares += _safeUint128(vaultSharesMinted);
        vaultMaturityPools[maturity] = maturityPool;

        // Update global vault shares storage
        _mint(account, vaultSharesMinted);
    }

    /**
     * @notice Redeems vault shares within a given maturity and updates account balances
     */
    function _redeemVaultSharesInMaturity(
        address account,
        uint256 maturity,
        uint256 vaultSharesToRedeem,
        MaturityPool memory maturityPool
    ) private returns (
        uint256 cashTokensWithdrawn,
        uint256 strategyTokensWithdrawn
    ) {
        // First update global supply storage
        _burn(account, vaultSharesToRedeem);

        // Calculate the claim on cash tokens and strategy tokens
        (cashTokensWithdrawn, strategyTokensWithdrawn) = _getPoolShare(maturityPool, vaultSharesToRedeem);

        // Remove tokens from the maturityPool and set the storage
        maturityPool.totalCashTokens -= _safeUint128(cashTokensWithdrawn);
        maturityPool.totalStrategyTokens -= _safeUint128(strategyTokensWithdrawn);
        maturityPool.totalVaultShares -= _safeUint128(vaultSharesToRedeem);
        vaultMaturityPools[maturity] = maturityPool;
    }

    function _getAccountValue(
        MaturityPool memory maturityPool,
        uint256 vaultShares,
        int256 assetCashExchangeRate
    ) internal view returns (uint256 underlyingValue) {
        (uint256 cashTokens, uint256 strategyTokens) = _getPoolShare(maturityPool, vaultShares);

        underlyingValue = 
            _convertStrategyToUnderlying(strategyTokens) +
            _convertToUnderlying(cashTokens, assetCashExchangeRate);
    }

    function _getPoolShare(
        MaturityPool memory maturityPool,
        uint256 vaultShares
    ) internal pure returns (
        uint256 cashTokens,
        uint256 strategyTokens
    ) {
        cashTokens = (vaultShares * maturityPool.totalCashTokens) / maturityPool.totalVaultShares;
        strategyTokens = (vaultShares * maturityPool.totalStrategyTokens) / maturityPool.totalVaultShares;
    }

    function getMaturityPoolShares(
        uint256 maturity,
        uint256 vaultShares
    ) public view returns (
        uint256 cashTokens,
        uint256 strategyTokens
    ) {
        MaturityPool memory maturityPool = vaultMaturityPools[maturity];
        return _getPoolShare(maturityPool, vaultShares);
    }

    function underlyingInternalValueOf(
        address account,
        uint256 maturity,
        int256 assetCashExchangeRate
    ) external view returns (int256 underlyingInternalValue) {
        MaturityPool memory maturityPool = vaultMaturityPools[maturity];
        underlyingInternalValue = _convertUnderlyingToInternalPrecision(
            _getAccountValue(maturityPool, balanceOf(account), assetCashExchangeRate)
        );
    }

    // function maturityPoolSharesOf(address account) public view returns (
    //     uint256 maturity,
    //     uint256 cashTokens,
    //     uint256 strategyTokens
    // ) external view returns (
    //     uint256 cashTokens,
    //     uint256 strategyTokens
    // ) {
    //     maturity = NOTIONAL.vaultMaturityOf(address(this), account);
    //     (cashTokens, strategyTokens) = getMaturityPoolShares(maturity, balanceOf(account));
    // }

    function _safeUint128(uint256 x) private pure returns (uint128) {
        require(x <= uint256(type(uint128).max));
        return uint128(x);
    }

    function _convertUnderlyingToInternalPrecision(
        uint256 underlyingExternalAmount
    ) internal view returns (int256) {
        uint256 x = (underlyingExternalAmount * INTERNAL_TOKEN_PRECISION)  / UNDERLYING_TOKEN_PRECISION;
        require(x <= uint256(type(int256).max));
        return int256(x);
    }

    function _convertToCashTokens(
        uint256 underlyingAmount,
        int256 assetExchangeRate
    ) internal view returns (uint256 cashTokenAmount) {
        require(assetExchangeRate > 0);
        cashTokenAmount = (underlyingAmount * UNDERLYING_TOKEN_PRECISION) / uint256(assetExchangeRate);
    }

    function _convertToUnderlying(
        uint256 cashTokenAmount,
        int256 assetExchangeRate
    ) internal view returns (uint256 underlyingTokenAmount) {
        require(assetExchangeRate > 0);
        underlyingTokenAmount = (cashTokenAmount * uint256(assetExchangeRate)) / UNDERLYING_TOKEN_PRECISION;
    }

    function _mintStrategyTokens(
        address account,
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata data
    ) internal virtual returns (uint256 cashTokensRaised);
    function _redeemStrategyTokens(
        address account,
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata data
    ) internal virtual returns (uint256 cashTokensRaised);
    function _convertStrategyToUnderlying(uint256 strategyTokens) internal view virtual returns (uint256 underlyingValue);
    function isInSettlement() external view virtual returns (bool);
    function canSettleMaturity(uint256 maturity) external view virtual returns (bool);

    // // // TODO: put these on the main vault actions
    // // function assetValueOf(address account) external view returns (int256);
    // // function assetInternalValueOf(address account) external view returns (int256);
    // // function leverageRatioFor(address account) external view returns (uint256);
    // // function escrowedCashBalance(address account) external view returns (uint256);
}