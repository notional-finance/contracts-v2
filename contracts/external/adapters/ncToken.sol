// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.17;

import {ERC20} from "@openzeppelin-4.6/contracts/token/ERC20/ERC20.sol";
import {CTokenInterface} from "../../../interfaces/compound/CTokenInterface.sol";
import {CEtherInterface} from "../../../interfaces/compound/CEtherInterface.sol";
import {CErc20Interface} from "../../../interfaces/compound/CErc20Interface.sol";
import {AssetRateAdapter} from "../../../interfaces/notional/AssetRateAdapter.sol";

contract ncToken is ERC20 {
    address public constant ETH_ADDRESS = address(0);

    address public immutable NOTIONAL;
    address public immutable COMPOUND_TOKEN;
    address public immutable UNDERLYING_TOKEN;
    uint8 public immutable CTOKEN_DECIMALS;
    uint256 public currentExchangeRate;

    event ExchangeRateUpdated(uint256 previous, uint256 current);

    modifier onlyNotional() {
        require(msg.sender == address(NOTIONAL));
        _;
    }

    constructor(address notional_, address cToken_, bool isETH) 
        ERC20(
            string(abi.encodePacked("Notional ", ERC20(cToken_).name())), 
            string(abi.encodePacked("n", ERC20(cToken_).symbol()))
        ) {
        CTOKEN_DECIMALS = ERC20(cToken_).decimals();
        COMPOUND_TOKEN = cToken_;
        NOTIONAL = notional_;
        UNDERLYING_TOKEN = isETH ? ETH_ADDRESS : CTokenInterface(cToken_).underlying();
    }

    function updateExchangeRate(uint256 newRate) external onlyNotional {
        emit ExchangeRateUpdated(currentExchangeRate, newRate);
        currentExchangeRate = newRate;
    }

    // ERC20 functions
    function decimals() public view override returns (uint8) {
        return CTOKEN_DECIMALS;
    }

    // CEtherInterface functions
    function mint() external payable onlyNotional {

    }

    // CErc20Interface functions 
    function mint(uint mintAmount) external onlyNotional returns (uint) {

    }

    function redeem(uint redeemTokens) external returns (uint) {

    }

    function redeemUnderlying(uint redeemAmount) external returns (uint) {

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
        return _toInt(currentExchangeRate);
    }

    function getExchangeRateView() external view returns (int256) {
        return _toInt(currentExchangeRate);
    }

    function getAnnualizedSupplyRate() external view returns (uint256) {
        return 0;
    }

    function _toInt(uint256 x) internal pure returns (int256) {
        require (x <= uint256(type(int256).max)); // dev: toInt overflow
        return int256(x);
    }
}
