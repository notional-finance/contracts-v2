// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.11;
pragma abicoder v2;

import "../global/Constants.sol";
import "./BaseStrategyVault.sol";
import "interfaces/chainlink/AggregatorInterface.sol";

/**
 * Simulates a vault that borrows in 2 or 3 currencies and provides "liquidity"
 * to a pool. Its strategy tokens have variable claims on the underlying borrowed
 * currencies.
 */
contract MultiBorrowStrategyVault is BaseStrategyVault {
    event SecondaryBorrow(int256[2] underlyingTokensTransferred);

    function strategy() external pure override returns (bytes4) {
        return bytes4(keccak256("MultiBorrowStrategyVault"));
    }

    int256[3] public nativeDecimals;
    ERC20[3] public tokens;

    uint16 public secondaryCurrencyOne;
    uint16 public secondaryCurrencyTwo;
    uint256 public totalStrategyTokens;

    AggregatorInterface[2] public oracles;

    struct DepositParams {
        uint256[2] secondaryBorrows;
    }

    struct RedeemParams {
        uint256[2] underlyingToRepay;
        int256[3] netTrades;
    }

    function approveTransfer(ERC20 token) external { 
        // Allow arbitrary token transfers to update pool balances
        token.approve(msg.sender, type(uint256).max);
        ERC20(token).approve(address(NOTIONAL), type(uint256).max);
    }

    function withdrawETH(uint256 amount) external { 
        payable(msg.sender).transfer(amount);
    }

    function getPoolBalances() public view returns (int256[3] memory poolBalances) { 
        poolBalances[0] = address(tokens[0]) == address(0) ? 
            int256(address(this).balance) :
            int256(tokens[0].balanceOf(address(this)));

        if (secondaryCurrencyOne != 0) {
            poolBalances[1] = address(tokens[1]) == address(0) ? 
                int256(address(this).balance) :
                int256(tokens[0].balanceOf(address(this)));
        }

        if (secondaryCurrencyTwo != 0) {
            poolBalances[2] = address(tokens[2]) == address(0) ? 
                int256(address(this).balance) :
                int256(tokens[0].balanceOf(address(this)));
        }
    }

    constructor(
        string memory name_,
        address notional_,
        uint16 borrowCurrencyId_,
        uint16 secondaryCurrencyOne_,
        uint16 secondaryCurrencyTwo_,
        AggregatorInterface[2] memory secondaryCurrencyToPrimaryOracle_
    ) BaseStrategyVault(name_, notional_, borrowCurrencyId_) {
        Token memory underlyingToken;
        (/* */, underlyingToken) = NotionalProxy(notional_).getCurrency(borrowCurrencyId_);
        nativeDecimals[0] = underlyingToken.decimals;
        tokens[0] = ERC20(underlyingToken.tokenAddress);

        if (secondaryCurrencyOne_ != 0) {
            secondaryCurrencyOne = secondaryCurrencyOne_;
            (/* */, underlyingToken) = NotionalProxy(notional_).getCurrency(secondaryCurrencyOne_);
            nativeDecimals[1] = underlyingToken.decimals;
            tokens[1] = ERC20(underlyingToken.tokenAddress);
            oracles[0] = secondaryCurrencyToPrimaryOracle_[0];
        }

        if (secondaryCurrencyOne_ != 1) {
            secondaryCurrencyTwo = secondaryCurrencyTwo_;
            (/* */, underlyingToken) = NotionalProxy(notional_).getCurrency(secondaryCurrencyTwo_);
            nativeDecimals[2] = underlyingToken.decimals;
            tokens[2] = ERC20(underlyingToken.tokenAddress);
            oracles[1] = secondaryCurrencyToPrimaryOracle_[1];
        }

        int256[3] memory poolBalances = getPoolBalances();
        totalStrategyTokens = uint256(poolBalances[0]);
    }

    // Vaults need to implement these two methods
    function _depositFromNotional(
        address account,
        uint256 deposit,
        uint256 maturity,
        bytes calldata data
    ) internal override returns (uint256 strategyTokensMinted) {
        DepositParams memory depositParams = abi.decode(data, (DepositParams));
        int256[3] memory poolBalances = getPoolBalances();

        // Borrow equal share of primary pool deposited in other pools in 1e8 decimals
        uint256[2] memory secondaryBorrow;
        if (secondaryCurrencyOne != 0 &&
            depositParams.secondaryBorrows[0] == 0) {
            secondaryBorrow[0] = uint256((int256(deposit) * poolBalances[1] * 1e8) / (poolBalances[0] * nativeDecimals[1]));
        } else {
            secondaryBorrow[0] = depositParams.secondaryBorrows[0];
        }

        if (secondaryCurrencyTwo != 0 &&
            depositParams.secondaryBorrows[1] == 0) {
            secondaryBorrow[1] = uint256((int256(deposit) * poolBalances[2] * 1e8) / (poolBalances[0] * nativeDecimals[2]));
        } else {
            secondaryBorrow[1] = depositParams.secondaryBorrows[1];
        }

        // Tokens will be transferred in from notional
        NOTIONAL.borrowSecondaryCurrencyToVault(
            account, maturity, secondaryBorrow, [uint32(0), uint32(0)], [uint32(0), uint32(0)]
        );

        // Mint strategy tokens based on the share of the primary pool balance deposited
        if (totalStrategyTokens == 0) {
            strategyTokensMinted = deposit * 1e8 / uint256(nativeDecimals[0]);
        } else {
            strategyTokensMinted = deposit * totalStrategyTokens / (uint256(poolBalances[0]) - deposit);
        }
        totalStrategyTokens += strategyTokensMinted;
    }

    event RedeemNetPoolClaims(int256[3] netPoolClaims, int256[2] transfers);

    function _redeemFromNotional(
        address account,
        uint256 strategyTokens,
        uint256 maturity,
        uint256 primaryToRepay,
        bytes calldata data
    ) internal override returns (uint256 primaryTokensRedeemed) {
        int256[3] memory netPoolClaims = getPoolClaims(strategyTokens);
        RedeemParams memory redeem = abi.decode(data, (RedeemParams));

        // ETH repayments need to be calculated up front
        uint256 msgValue;
        if (
            secondaryCurrencyOne == Constants.ETH_CURRENCY_ID &&
            redeem.underlyingToRepay[0] > 0
        ) {
            (msgValue, redeem.underlyingToRepay[0]) = _calculateETHRepayAmount(
                uint16(Constants.ETH_CURRENCY_ID), account, redeem.underlyingToRepay[0], maturity
            );
        } else if (
            secondaryCurrencyTwo == Constants.ETH_CURRENCY_ID &&
            redeem.underlyingToRepay[1] > 0
        ) {
            (msgValue, redeem.underlyingToRepay[1])= _calculateETHRepayAmount(
                uint16(Constants.ETH_CURRENCY_ID), account, redeem.underlyingToRepay[1], maturity
            );
        }

        int256[2] memory transfers = NOTIONAL.repaySecondaryCurrencyFromVault{value: msgValue}(
            account, maturity, redeem.underlyingToRepay, [uint32(0), uint32(0)]
        );

        // Positive transfers are payments
        // Negative transfers are refunds
        netPoolClaims[1] -= transfers[0];
        netPoolClaims[2] -= transfers[1];

        // Net trades between primary and secondary one
        netPoolClaims[0] -= redeem.netTrades[0];
        netPoolClaims[1] += calculateTrade(0, 1, redeem.netTrades[0]);

        if (secondaryCurrencyTwo != 0) {
            // Net trades between primary and secondary two
            netPoolClaims[0] -= redeem.netTrades[1];
            netPoolClaims[2] += calculateTrade(0, 2, redeem.netTrades[1]);

            // Net trades between secondaries
            netPoolClaims[1] -= redeem.netTrades[2];
            netPoolClaims[2] += calculateTrade(1, 2, redeem.netTrades[2]);
        }

        require(netPoolClaims[0] >= 0, "primary claim neg"); 
        require(netPoolClaims[1] >= 0, "secondary one neg");
        require(netPoolClaims[2] >= 0, "secondary two neg");

        primaryTokensRedeemed = uint256(netPoolClaims[0]);
        // Transfer out pool claims 1 and 2
        if (secondaryCurrencyOne != 0 && netPoolClaims[1] > 0) {
            _transferTokens(tokens[1], account, netPoolClaims[1]);
        }

        if (secondaryCurrencyTwo != 0 && netPoolClaims[2] > 0) {
            _transferTokens(tokens[2], account, netPoolClaims[2]);
        }

        emit RedeemNetPoolClaims(netPoolClaims, transfers);

        totalStrategyTokens -= strategyTokens;
    }

    function convertStrategyToUnderlying(
        address /* account */, uint256 strategyTokens, uint256 /* maturity */
    ) public view override returns (int256 underlyingValue) {
        int256[3] memory netPoolClaims = getPoolClaims(strategyTokens);
        underlyingValue = netPoolClaims[0];

        if (secondaryCurrencyOne != 0) {
            int256 answer = oracles[0].latestAnswer();
            underlyingValue += (netPoolClaims[1] * 1e18) / answer;
        }

        if (secondaryCurrencyTwo != 0) {
            int256 answer = oracles[1].latestAnswer();
            underlyingValue += (netPoolClaims[2] * 1e18) / answer;
        }
    }

    function getPoolClaims(uint256 strategyTokens) public view returns (int256[3] memory netPoolClaims) {
        int256[3] memory poolBalances = getPoolBalances();
        if (totalStrategyTokens == 0) return netPoolClaims;

        netPoolClaims[0] = int256(strategyTokens) * poolBalances[0] / int256(totalStrategyTokens);
        netPoolClaims[1] = int256(strategyTokens) * poolBalances[1] / int256(totalStrategyTokens);
        netPoolClaims[2] = int256(strategyTokens) * poolBalances[2] / int256(totalStrategyTokens);
    }

    function calculateTrade(uint256 purchased, uint256 sold, int256 amountSold) public view returns (int256 amountPurchased) {
        if (amountSold == 0) return 0;

        int256 oracleSold = sold == 0 ? int256(1e18) : int256(1e36) / oracles[sold - 1].latestAnswer();
        int256 oraclePurchase = purchased == 0 ? int256(1e18) : int256(1e36) / oracles[purchased - 1].latestAnswer();
        amountPurchased = (amountSold * oraclePurchase * nativeDecimals[purchased]) / (oracleSold * nativeDecimals[sold]);
    }

    function _transferTokens(ERC20 token, address account, int256 netPoolClaim) internal {
        if (netPoolClaim == 0) return;
        require(netPoolClaim > 0);

        if (address(token) == address(0)) {
            payable(account).transfer(uint256(netPoolClaim));
        } else {
            token.transfer(account, uint256(netPoolClaim));
        }
    }

    function _calculateETHRepayAmount(
        uint16 currencyId,
        address account,
        uint256 fCashToRepay,
        uint256 maturity
    ) internal view returns (uint256 msgValue, uint256 amountToRepay) {
        (
            /* */,
            int256[2] memory accountUnderlyingDebt,
            int256[2] memory accountSecondaryCashHeld
        ) = NOTIONAL.getVaultAccountSecondaryDebt(account, address(this));
        amountToRepay = fCashToRepay;

        if (maturity == Constants.PRIME_CASH_VAULT_MATURITY) {
            amountToRepay = fCashToRepay == type(uint256).max ? uint256(-accountUnderlyingDebt[0]) : fCashToRepay;
            msgValue = amountToRepay * 1e10;
        } else {
            (msgValue, /* */, /* */, /* */) = NOTIONAL.getDepositFromfCashLend(
                uint16(Constants.ETH_CURRENCY_ID), fCashToRepay, maturity, 0, block.timestamp
            );
            if (msgValue == 0) msgValue = fCashToRepay * 1e10;
        }

        int256 refundedCash = accountSecondaryCashHeld[0];
        if (refundedCash > 0) {
            uint256 refundUnderlying = uint256(NOTIONAL.convertCashBalanceToExternal(currencyId, refundedCash, true));
            if (refundUnderlying >= msgValue) return (0, amountToRepay);

            msgValue = msgValue - refundUnderlying;
        }

        // Accounts for any ETH refunds the account will receive
        msgValue += 1e10;
    }
}