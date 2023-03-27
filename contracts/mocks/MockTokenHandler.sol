// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../internal/AccountContextHandler.sol";
import "../internal/balances/BalanceHandler.sol";
import "../internal/balances/TokenHandler.sol";
import "../internal/nToken/nTokenHandler.sol";
import "../internal/nToken/nTokenSupply.sol";
import "../internal/pCash/PrimeCashExchangeRate.sol";
import "../internal/pCash/PrimeRateLib.sol";
import "./valuation/AbstractSettingsRouter.sol";

contract MockTokenHandler is AbstractSettingsRouter {
    using TokenHandler for Token;
    using BalanceHandler for BalanceState;
    using AccountContextHandler for AccountContext;
    using PrimeRateLib for PrimeRate;

    constructor(address settingsLib) AbstractSettingsRouter(settingsLib) { }

    /// @notice Emitted when a cash balance changes
    event CashBalanceChange(address indexed account, uint16 indexed currencyId, int256 netCashChange);
    /// @notice Emitted when nToken supply changes (not the same as transfers)
    event nTokenSupplyChange(address indexed account, uint16 indexed currencyId, int256 tokenSupplyChange);

    /// @notice Emits every time interest is accrued
    event PrimeCashInterestAccrued(uint16 indexed currencyId);

    /// @notice Emits when the totalPrimeDebt changes due to borrowing
    event PrimeDebtChanged(
        uint16 indexed currencyId,
        uint256 totalPrimeSupply,
        uint256 totalPrimeDebt
    );

    /// @notice Emits when the totalPrimeSupply changes due to token deposits or withdraws
    event PrimeSupplyChanged(
        uint16 indexed currencyId,
        uint256 totalPrimeSupply,
        uint256 lastTotalUnderlyingValue
    );

    event PrimeCashCurveChanged(uint16 indexed currencyId);

    event PrimeCashHoldingsOracleUpdated(uint16 indexed currencyId, address oracle);

    event ReserveFeeAccrued(uint16 indexed currencyId, int256 fee);

    function getPrimeCashFactors(
        uint16 currencyId
    ) external view returns (PrimeCashFactors memory p) {
        return PrimeCashExchangeRate.getPrimeCashFactors(currencyId);
    }

    function getPrimeInterestRates(
        uint16 currencyId
    ) external view returns (
        uint256 annualDebtRatePreFee,
        uint256 annualDebtRatePostFee,
        uint256 annualSupplyRate
    ) {
        PrimeCashFactors memory p = PrimeCashExchangeRate.getPrimeCashFactors(currencyId);
        return PrimeCashExchangeRate.getPrimeInterestRates(currencyId, p);
    }

    function convertToUnderlying(
        PrimeRate memory pr,
        int256 primeCashBalance
    ) external pure returns (int256) {
        return pr.convertToUnderlying(primeCashBalance);
    }

    function convertFromUnderlying(
        PrimeRate memory pr,
        int256 underlyingBalance
    ) external pure returns (int256) {
        return pr.convertFromUnderlying(underlyingBalance);
    }
    
    function buildPrimeRateView(
        uint16 currencyId,
        uint256 blockTime
    ) public view returns (PrimeRate memory, PrimeCashFactors memory) {
        return PrimeCashExchangeRate.getPrimeCashRateView(currencyId, blockTime);
    }

    function buildPrimeRateStateful(
        uint16 currencyId
    ) external returns (PrimeRate memory) {
        return PrimeRateLib.buildPrimeRateStateful(currencyId);
    }

    function setToken(uint256 id, TokenStorage calldata ts) external {
        return TokenHandler.setToken(id, ts);
    }

    function setAssetToken(uint256 id, TokenStorage calldata ts) external {
        mapping(uint256 => mapping(bool => TokenStorage)) storage store = LibStorage.getTokenStorage();
        store[id][false] = ts;
    }

    function getToken(uint16 currencyId) external view returns (Token memory) {
        return TokenHandler.getUnderlyingToken(currencyId);
    }

    function setMaxUnderlyingSupply(uint16 currencyId, uint256 maxUnderlying) external {
        PrimeCashExchangeRate.setMaxUnderlyingSupply(currencyId, maxUnderlying);
    }

    function getSupplyCap(uint16 currencyId) external view returns (uint256 maxUnderlying, uint256 totalUnderlying) {
        (PrimeRate memory pr, /* */) = buildPrimeRateView(currencyId, block.timestamp);
        return pr.getSupplyCap(currencyId);
    }

    function setAccountContext(address account, AccountContext memory a) external {
        a.setAccountContext(account);
    }

    function enablePrimeBorrow(address account) external {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        accountContext.allowPrimeBorrow = true;
        accountContext.setAccountContext(account);
    }

    event DepositExact(int256 actualTransferExternal, PrimeRate pr);
    function depositExactToMintPrimeCash(
        address account,
        uint16 currencyId,
        int256 primeCashToMint,
        bool wrapETH
    ) external payable returns (int256 actualTransferExternal, PrimeRate memory pr) {
        pr = PrimeRateLib.buildPrimeRateStateful(currencyId);
        actualTransferExternal = TokenHandler.depositExactToMintPrimeCash(account, currencyId, primeCashToMint, pr, wrapETH);
        emit DepositExact(actualTransferExternal, pr);
    }

    event WithdrawPCash(int256 actualTransferExternal, PrimeRate pr);
    function withdrawPrimeCash(
        address account,
        uint16 currencyId,
        int256 primeCashToWithdraw,
        bool wrapETH
    ) external returns (int256 actualTransferExternal, PrimeRate memory pr) {
        pr = PrimeRateLib.buildPrimeRateStateful(currencyId);
        actualTransferExternal = TokenHandler.withdrawPrimeCash(account, currencyId, primeCashToWithdraw, pr, wrapETH);
        emit WithdrawPCash(actualTransferExternal, pr);
    }

    function depositUnderlyingExternal(
        address account,
        uint16 currencyId,
        int256 underlyingExternalDeposit,
        bool wrapETH
    ) external payable returns (int256 actualTransferExternal, int256 primeCashMinted, PrimeRate memory pr) {
        pr = PrimeRateLib.buildPrimeRateStateful(currencyId);
        (actualTransferExternal, primeCashMinted) = TokenHandler.depositUnderlyingExternal(account, currencyId, underlyingExternalDeposit, pr, wrapETH);
    }

    function depositUnderlyingExternalCheckSupply(
        address account,
        uint16 currencyId,
        int256 underlyingExternalDeposit,
        bool wrapETH
    ) external payable {
        PrimeRate memory pr = PrimeRateLib.buildPrimeRateStateful(currencyId);
        TokenHandler.depositUnderlyingExternal(account, currencyId, underlyingExternalDeposit, pr, wrapETH);
        pr.checkSupplyCap(currencyId);
    }

    function setBalance(
        address account,
        uint16 currencyId,
        int256 cashBalance,
        int256 nTokenBalance
    ) external {
        PrimeRate memory pr = PrimeRateLib.buildPrimeRateStateful(currencyId);
        BalanceHandler._setBalanceStorage(account, currencyId, cashBalance, nTokenBalance, 0, 0, pr);
    }

    function getBalance(
        address account,
        uint16 currencyId
    ) external view returns (BalanceStorage memory) {
        mapping(address => mapping(uint256 => BalanceStorage)) storage store = LibStorage.getBalanceStorage();
        BalanceStorage storage balanceStorage = store[account][currencyId];
        return balanceStorage;
    }

    function getPositiveCashBalance(
        address account,
        uint16 currencyId
    ) external view returns (int256 cashBalance) {
        return BalanceHandler.getPositiveCashBalance(account, currencyId);
    }

    function setPositiveCashBalance(address account, uint16 currencyId, int256 newCashBalance) external {
        return BalanceHandler._setPositiveCashBalance(account, currencyId, newCashBalance);
    }

    event Finalize(AccountContext accountContext, int256 transferAmountExternal, PrimeRate primeRate);
    function finalize(
        BalanceState memory balanceState,
        address account,
        bool withdrawWrapped
    ) public returns (AccountContext memory, int256) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        balanceState.primeRate = PrimeRateLib.buildPrimeRateStateful(balanceState.currencyId);
        int256 transferAmountExternal = balanceState.finalizeWithWithdraw(account, accountContext, withdrawWrapped);
        AccountContextHandler.setAccountContext(accountContext, account);

        emit Finalize(accountContext, transferAmountExternal, balanceState.primeRate);
        return (accountContext, transferAmountExternal);
    }

    function loadBalanceState(
        address account,
        uint16 currencyId
    ) public view returns (BalanceState memory, AccountContext memory) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState memory bs;
        bs.loadBalanceStateView(account, currencyId, accountContext);

        return (bs, accountContext);
    }

    event DepositUnderlying(BalanceState balanceState, int256 primeCashDeposited);
    function depositDeprecatedAssetToken(
        address account,
        uint16 currencyId,
        int256 assetAmountExternal
    ) external returns (BalanceState memory, int256) {
        BalanceState memory balanceState;
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        balanceState.loadBalanceState(account, currencyId, accountContext);
        int256 primeCashDeposited = balanceState.depositDeprecatedAssetToken(
            account,
            assetAmountExternal
        );

        emit DepositUnderlying(balanceState, primeCashDeposited);
        return (balanceState, primeCashDeposited);
    }

    function depositUnderlyingToken(
        address account,
        uint16 currencyId,
        int256 underlyingAmountExternal,
        bool returnExcessWrapped
    ) external payable returns (BalanceState memory, int256) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        BalanceState memory balanceState;
        balanceState.loadBalanceState(account, currencyId, accountContext);
        int256 primeCashDeposited = balanceState.depositUnderlyingToken(
            account,
            underlyingAmountExternal,
            returnExcessWrapped
        );

        emit DepositUnderlying(balanceState, primeCashDeposited);
        return (balanceState, primeCashDeposited);
    }

    function convertToExternal(uint16 currencyId, int256 amount) external view returns (int256) {
        return TokenHandler.convertToExternal(
            TokenHandler.getUnderlyingToken(currencyId),
            amount
        );
    }

    function convertToExternalAdjusted(uint16 currencyId, int256 amount) external view returns (int256) {
        return TokenHandler.convertToUnderlyingExternalWithAdjustment(
            TokenHandler.getUnderlyingToken(currencyId),
            amount
        );
    }

    function convertToInternal(uint16 currencyId, int256 amount) external view returns (int256) {
        return TokenHandler.convertToInternal(
            TokenHandler.getUnderlyingToken(currencyId),
            amount
        );
    }

    function setBalanceStorageForfCashLiquidation(
        address account,
        uint16 currencyId,
        int256 netPrimeCashChange
    ) external returns (AccountContext memory) {
        AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);
        PrimeRate memory primeRate = PrimeRateLib.buildPrimeRateStateful(currencyId);

        BalanceHandler.setBalanceStorageForfCashLiquidation(
            account,
            accountContext,
            currencyId,
            netPrimeCashChange,
            primeRate
        );

        return accountContext;
    }
        
    function setIncentives(
        uint16 currencyId,
        address nTokenAddress
    ) external {
        nTokenHandler.setNTokenAddress(currencyId, nTokenAddress);
        nTokenSupply.setIncentiveEmissionRate(nTokenAddress, 100_000, block.timestamp);
    }
}
