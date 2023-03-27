// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;

import "../../../interfaces/notional/AssetRateAdapter.sol";
import "../../../interfaces/compound/CTokenInterface.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

abstract contract cTokenAggregator is AssetRateAdapter {
    using SafeMath for uint256;

    address public immutable INTEREST_RATE_MODEL;
    CTokenInterface internal immutable cToken;
    uint8 public override decimals = 18;
    uint256 public override version = 1;
    string public override description;
    // This is defined in the Compound interest rate model:
    // https://github.com/compound-finance/compound-protocol/blob/b9b14038612d846b83f8a009a82c38974ff2dcfe/contracts/JumpRateModel.sol#L18
    uint256 public constant BLOCKS_PER_YEAR = 2102400;
    // Notional rate precision = 1e9
    // Compound rate precision = 1e18
    uint256 public constant SCALE_RATE = 1e9;

    constructor(CTokenInterface _cToken) {
        cToken = _cToken;
        description = ERC20(address(_cToken)).symbol();
        INTEREST_RATE_MODEL = _cToken.interestRateModel();
    }

    function token() external view override returns (address) {
        return address(cToken);
    }

    function underlying() external view override returns (address) {
        return cToken.underlying();
    }

    function _checkExchangeRate(uint256 exchangeRate) private pure {
        require(exchangeRate <= uint256(type(int256).max), "cTokenAdapter: overflow");
    }

    function _getBorrowRate(
        uint256 totalCash,
        uint256 borrowsPrior,
        uint256 reservesPrior
    ) internal view virtual returns (uint256);

    /// @dev adapted from https://github.com/transmissions11/libcompound/blob/main/src/LibCompound.sol
    function _viewExchangeRate() private view returns (uint256) {
        uint256 accrualBlockNumberPrior = cToken.accrualBlockNumber();

        if (accrualBlockNumberPrior == block.number) return cToken.exchangeRateStored();

        uint256 totalCash = cToken.getCash();
        uint256 borrowsPrior = cToken.totalBorrows();
        uint256 reservesPrior = cToken.totalReserves();

        // There are two versions of this method depending on the interest rate model that
        // have different return signatures.
        uint256 borrowRateMantissa = _getBorrowRate(totalCash, borrowsPrior, reservesPrior);

        require(borrowRateMantissa <= 0.0005e16, "RATE_TOO_HIGH"); // Same as borrowRateMaxMantissa in CTokenInterfaces.sol

        // Interest accumulated = (borrowRate * blocksSinceLastAccrual * borrowsPrior) / 1e18
        uint256 interestAccumulated = borrowRateMantissa
            .mul(block.number.sub(accrualBlockNumberPrior))
            .mul(borrowsPrior)
            .div(1e18);

        // Total Reserves = total reserves prior + (interestAccumulated * reserveFactor) / 1e18
        uint256 totalReserves = cToken.reserveFactorMantissa().mul(interestAccumulated).div(1e18).add(reservesPrior);
        // Total borrows = interestAccumulated + borrowsPrior
        uint256 totalBorrows = interestAccumulated.add(borrowsPrior);
        uint256 totalSupply = cToken.totalSupply();

        // exchangeRate = ((totalCash + totalBorrows - totalReserves) * 1e18) / totalSupply
        // https://github.com/compound-finance/compound-protocol/blob/master/contracts/CToken.sol#L350
        return
            totalSupply == 0
                ? cToken.initialExchangeRateMantissa()
                : (totalCash.add(totalBorrows).sub(totalReserves)).mul(1e18).div(totalSupply);
    }

    /** @notice Returns the current exchange rate for the cToken to the underlying */
    function getExchangeRateStateful() external override returns (int256) {
        uint256 exchangeRate = cToken.exchangeRateCurrent();
        _checkExchangeRate(exchangeRate);

        return int256(exchangeRate);
    }

    function getExchangeRateView() external view override returns (int256) {
        // Return stored exchange rate if interest rate model is updated.
        // This prevents the function from returning incorrect exchange rates
        uint256 exchangeRate = cToken.interestRateModel() == INTEREST_RATE_MODEL
            ? _viewExchangeRate()
            : cToken.exchangeRateStored();
        _checkExchangeRate(exchangeRate);

        return int256(exchangeRate);
    }

    function getAnnualizedSupplyRate() external view override returns (uint256) {
        uint256 supplyRatePerBlock = cToken.supplyRatePerBlock();

        // Although the Compound documentation recommends doing a per day compounding of the supply
        // rate to get the annualized rate (https://compound.finance/docs#protocol-math), we just do a
        // simple linear approximation of the rate here. Since Compound rates are variable per block
        // any rate we calculate here will be an approximation and so this is the simplest implementation
        // that gets a pretty good answer. Supply rates are only used when valuing idiosyncratic fCash assets
        // that are shorter dated than the 3 month fCash market.

        // Supply rate per block * blocks per year * notional rate precision / supply rate precision
        return supplyRatePerBlock.mul(BLOCKS_PER_YEAR).div(SCALE_RATE);
    }
}
