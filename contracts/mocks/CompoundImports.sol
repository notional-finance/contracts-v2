pragma solidity ^0.5.16;

import "compound-finance/compound-protocol@2.8.1/contracts/Comptroller.sol";
import "compound-finance/compound-protocol@2.8.1/contracts/CErc20Immutable.sol";
import "compound-finance/compound-protocol@2.8.1/contracts/CEther.sol";
import "compound-finance/compound-protocol@2.8.1/contracts/WhitePaperInterestRateModel.sol";
import "compound-finance/compound-protocol@2.8.1/contracts/JumpRateModel.sol";
import "compound-finance/compound-protocol@2.8.1/contracts/SimplePriceOracle.sol";

contract nComptroller is Comptroller {
    constructor() public Comptroller() {}
}

contract nPriceOracle is SimplePriceOracle { }

contract nCErc20 is CErc20Immutable { 
    constructor(address underlying_,
            ComptrollerInterface comptroller_,
            InterestRateModel interestRateModel_,
            uint initialExchangeRateMantissa_,
            string memory name_,
            string memory symbol_,
            uint8 decimals_,
            address payable admin_) public
        CErc20Immutable(underlying_, comptroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_, admin_) { }
}

contract nCEther is CEther { 
    constructor(ComptrollerInterface comptroller_,
                InterestRateModel interestRateModel_,
                uint initialExchangeRateMantissa_,
                string memory name_,
                string memory symbol_,
                uint8 decimals_,
                address payable admin_) public
        CEther(comptroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_, admin_) { }
}

contract nJumpRateModel is JumpRateModel {
    constructor(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint kink_) public 
        JumpRateModel(baseRatePerYear, multiplierPerYear, jumpMultiplierPerYear, kink_) { }
}

contract nWhitePaperInterestRateModel is WhitePaperInterestRateModel {
    constructor(uint baseRatePerYear, uint multiplierPerYear) public
        WhitePaperInterestRateModel(baseRatePerYear, multiplierPerYear) {}
}