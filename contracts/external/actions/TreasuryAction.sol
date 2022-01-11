// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../../math/SafeInt256.sol";
import "../../internal/balances/BalanceHandler.sol";
import "../../internal/balances/TokenHandler.sol";
import "../../global/StorageLayoutV2.sol";
import "../../global/Constants.sol";
import "interfaces/notional/NotionalTreasury.sol";
import "interfaces/compound/ComptrollerInterface.sol";
import "interfaces/compound/CErc20Interface.sol";
import "interfaces/WETH9.sol";

contract TreasuryAction is StorageLayoutV2, NotionalTreasury {
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using SafeERC20 for IERC20;

    IERC20 public immutable COMP;
    Comptroller public immutable COMPTROLLER;
    address public immutable WETH;

    /// @dev Throws if called by any account other than the owner.
    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    modifier onlyManagerContract() {
        require(treasuryManagerContract == msg.sender, "Caller is not the treasury manager");
        _;
    }

    constructor(
        IERC20 _comp,
        Comptroller _comptroller,
        address _weth
    ) {
        COMP = _comp;
        COMPTROLLER = _comptroller;
        WETH = _weth;
        treasuryManagerContract = address(0);
    }

    function claimCOMP(address[] calldata ctokens)
        external
        override
        onlyManagerContract
        returns (uint256)
    {
        COMPTROLLER.claimComp(address(this), ctokens);
        uint256 bal = COMP.balanceOf(address(this));
        COMP.transfer(treasuryManagerContract, bal);
        return bal;
    }

    function transferReserveToTreasury(address[] calldata assets)
        external
        override
        onlyManagerContract
        returns (uint256[] memory)
    {
        uint256[] memory amountsTransferred = new uint256[](assets.length);

        for (uint256 i; i < assets.length; i++) {
            uint16 currencyId = tokenAddressToCurrencyId[assets[i]];
            require(currencyId != 0, "Token not listed");

            // prettier-ignore
            (int256 reserve, /* */, /* */, /* */) = BalanceHandler.getBalanceStorage(Constants.RESERVE, currencyId);
            Token memory token = TokenHandler.getAssetToken(currencyId);

            uint256 totalReserve = reserve.toUint();
            uint256 totalBalance = IERC20(token.tokenAddress).balanceOf(address(this));
            uint256 buffer = reserveBuffer[currencyId];

            // Reserve requirement not defined
            if (buffer == 0) continue;

            uint256 requiredReserve = totalBalance.mul(buffer).div(
                uint256(Constants.INTERNAL_TOKEN_PRECISION)
            );

            if (totalReserve > requiredReserve) {
                uint256 redeemAmount = totalReserve.sub(requiredReserve);
                Token memory underlying = TokenHandler.getUnderlyingToken(currencyId);
                amountsTransferred[i] = _redeemCToken(
                    token.tokenAddress,
                    underlying.tokenAddress,
                    redeemAmount
                );

                // _redeemCToken wraps ETH into WETH
                address underlyingAddress = underlying.tokenAddress == address(0)
                    ? WETH
                    : underlying.tokenAddress;
                IERC20(underlyingAddress).safeTransfer(
                    treasuryManagerContract,
                    amountsTransferred[i]
                );
            }
        }

        return amountsTransferred;
    }

    function _redeemCToken(
        address asset,
        address underlying,
        uint256 amount
    ) internal returns (uint256) {
        CErc20Interface(asset).redeem(amount);
        uint256 redeemed;

        if (underlying == address(0)) {
            redeemed = address(this).balance;
            WETH9(WETH).deposit{value: redeemed}();
        } else {
            redeemed = IERC20(underlying).balanceOf(address(this));
        }

        return redeemed;
    }

    function getTreasuryManager() external view override returns (address) {
        return treasuryManagerContract;
    }

    function setTreasuryManager(address manager) external override onlyOwner {
        treasuryManagerContract = manager;
    }

    function getReserveBuffer(uint16 currencyId) external view override returns (uint256) {
        return reserveBuffer[currencyId];
    }

    function setReserveBuffer(uint16 currencyId, uint256 amount) external override onlyOwner {
        require(currencyId <= Constants.MAX_CURRENCIES, "T: max currency overflow");
        require(amount <= uint256(Constants.INTERNAL_TOKEN_PRECISION), "T: amount too large");
        reserveBuffer[currencyId] = amount;
    }
}
