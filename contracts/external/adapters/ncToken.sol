// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.17;

import {ERC20} from "@openzeppelin-4.6/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin-4.6/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin-4.6/contracts/security/ReentrancyGuard.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {CTokenInterface} from "../../../interfaces/compound/CTokenInterface.sol";
import {CEtherInterface} from "../../../interfaces/compound/CEtherInterface.sol";
import {CErc20Interface} from "../../../interfaces/compound/CErc20Interface.sol";
import {AssetRateAdapter} from "../../../interfaces/notional/AssetRateAdapter.sol";
import {NotionalProxy} from "../../../interfaces/notional/NotionalProxy.sol";

contract ncToken is ERC20Upgradeable, ReentrancyGuard, UUPSUpgradeable {
    using SafeERC20 for ERC20;

    address public constant ETH_ADDRESS = address(0);
    uint256 internal constant EXCHANGE_RATE_PRECISION = 1e18;
    uint256 internal constant NO_ERROR = 0;

    address public immutable NOTIONAL;
    address public immutable COMPOUND_TOKEN;
    address public immutable UNDERLYING_TOKEN;
    uint8 internal immutable CTOKEN_DECIMALS;
    uint256 public immutable FINAL_EXCHANGE_RATE;

    mapping(address => uint256) public balanceOfUnderlying;

    modifier onlyNotionalOwner() {
        require(msg.sender == NotionalProxy(NOTIONAL).owner());
        _;
    }

    constructor(address notional_, address cToken_, bool isETH_, uint256 finalExchangeRate_) initializer {
        CTOKEN_DECIMALS = ERC20(cToken_).decimals();
        COMPOUND_TOKEN = cToken_;
        NOTIONAL = notional_;
        UNDERLYING_TOKEN = isETH_ ? ETH_ADDRESS : CTokenInterface(cToken_).underlying();
        FINAL_EXCHANGE_RATE = finalExchangeRate_;
    }

    function initialize() external initializer onlyNotionalOwner {
        __ERC20_init(
            string(abi.encodePacked("Notional ", ERC20(COMPOUND_TOKEN).name())), 
            string(abi.encodePacked("n", ERC20(COMPOUND_TOKEN).symbol()))
        );
    }

    // ERC20 functions
    function decimals() public view override returns (uint8) {
        return CTOKEN_DECIMALS;
    }

    // CEtherInterface functions
    function mint() external payable nonReentrant {
        require(UNDERLYING_TOKEN == ETH_ADDRESS);

        if (msg.value == 0) return;

        balanceOfUnderlying[msg.sender] += msg.value;
        uint256 assetTokenAmount = _convertToAsset(msg.value);

        // Handles event emission, balance update and total supply update
        super._mint(msg.sender, assetTokenAmount);
    }

    // CErc20Interface functions 
    function mint(uint mintAmount) external nonReentrant returns (uint) {
        require(UNDERLYING_TOKEN != ETH_ADDRESS);

        if (mintAmount == 0) return NO_ERROR;

        ERC20(UNDERLYING_TOKEN).safeTransferFrom(
            msg.sender,
            address(this),
            mintAmount
        );
        balanceOfUnderlying[msg.sender] += mintAmount;
        uint256 assetTokenAmount = _convertToAsset(mintAmount);

        // Handles event emission, balance update and total supply update
        super._mint(msg.sender, assetTokenAmount);

        return NO_ERROR;
    }

    function redeem(uint redeemTokens) external nonReentrant returns (uint) {
        if (redeemTokens == 0) return NO_ERROR;

        uint256 underlyingTokenAmount = _convertToUnderlying(redeemTokens);
        balanceOfUnderlying[msg.sender] -= underlyingTokenAmount;

        // Handles event emission, balance update and total supply update
        super._burn(msg.sender, redeemTokens);

        _transferUnderlyingToSender(underlyingTokenAmount);
        
        return NO_ERROR;
    }

    function redeemUnderlying(uint redeemAmount) external nonReentrant returns (uint) {
        if (redeemAmount == 0) return NO_ERROR;

        uint256 assetTokenAmount = _convertToAsset(redeemAmount);
        balanceOfUnderlying[msg.sender] -= redeemAmount;

        // Handles event emission, balance update and total supply update
        super._burn(msg.sender, assetTokenAmount);

        _transferUnderlyingToSender(redeemAmount);

        return NO_ERROR;
    }

    function _transferUnderlyingToSender(uint256 amount) private {
        if (UNDERLYING_TOKEN == ETH_ADDRESS) {
            payable(msg.sender).transfer(amount);
        } else {
            ERC20(UNDERLYING_TOKEN).safeTransfer(msg.sender, amount);
        }
    }

    // AssetRateAdapter functions
    function token() external view returns (address) {
        return COMPOUND_TOKEN;
    }

    function description() external view returns (string memory) {
        return super.symbol();
    }

    function version() external view returns (uint256) {
        return 1;
    }

    function underlying() external view returns (address) {
        return UNDERLYING_TOKEN;
    }

    function getExchangeRateStateful() external returns (int256) {
        return _toInt(FINAL_EXCHANGE_RATE);
    }

    function getExchangeRateView() external view returns (int256) {
        return _toInt(FINAL_EXCHANGE_RATE);
    }

    function getAnnualizedSupplyRate() external view returns (uint256) {
        return 0;
    }

    function _toInt(uint256 x) private pure returns (int256) {
        require (x <= uint256(type(int256).max)); // dev: toInt overflow
        return int256(x);
    }

    function _convertToAsset(uint256 underlyingAmount) private view returns (uint256) {
        return underlyingAmount * EXCHANGE_RATE_PRECISION / FINAL_EXCHANGE_RATE;
    }

    function _convertToUnderlying(uint256 assetAmount) private view returns (uint256) {
        return assetAmount * FINAL_EXCHANGE_RATE / EXCHANGE_RATE_PRECISION;
    }

    function _authorizeUpgrade(
        address /* newImplementation */
    ) internal override onlyNotionalOwner {}
}
