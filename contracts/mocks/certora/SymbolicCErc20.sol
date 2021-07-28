// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;


import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../../interfaces/compound/CErc20Interface.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";


contract SymbolicCErc20 is ERC20, CErc20Interface {
    using SafeMath for uint256;

    uint256 public constant EXP_SCALE = 1e18;  //Exponential scale (see Compound Exponential)
    uint256 public constant INTEREST_RATE = 10 * EXP_SCALE / 100;  // Annual interest 10%
    uint256 public constant INITIAL_RATE = 200000000000000000000000000;    // Same as real cDAI
    uint256 public constant ANNUAL_SECONDS = 365*24*60*60+(24*60*60/4);  // Seconds in a year + 1/4 day to compensate leap years
    uint256 private constant NO_ERROR = 0;

    mapping (address =>  uint256) borrowed;
    //todo - consider having an underlying 

   /* IERC20 underlying; */
    constructor (string memory name_, string memory symbol_) ERC20(name_,symbol_) {
    }

   mapping (uint256 =>  uint256) symbolicMintedAmount;
    function mint(uint mintAmount) public override returns (uint256) {
        // underlying.transferFrom(msg.sender, address(this), mintAmount);
        uint256 amount = symbolicMintedAmount[mintAmount];
        _mint(msg.sender, amount);
        return NO_ERROR;
    }

    mapping (uint256 =>  uint256) symbolicRedeemTokensToRedeemAmount;
    mapping (uint256 =>  uint256) symbolicRedeemAmountToRedeemToken;
   
    function redeem(uint redeemTokens) public override returns (uint256) {
        uint256 redeemAmount = symbolicRedeemTokensToRedeemAmount[redeemTokens];
        require(symbolicRedeemAmountToRedeemToken[redeemAmount] == redeemTokens);
        _burn(msg.sender, redeemTokens);
        _sendUnderlyuing(msg.sender, redeemAmount);
        return NO_ERROR;
    }
    
    function redeemUnderlying(uint redeemAmount) public override returns (uint256) {
        uint256 redeemTokens = symbolicRedeemAmountToRedeemToken[redeemAmount];
        require(symbolicRedeemTokensToRedeemAmount[redeemTokens] == redeemAmount);
        _burn(msg.sender, redeemTokens);
        _sendUnderlyuing(msg.sender, redeemAmount);
        return NO_ERROR;
    }

    function _sendUnderlyuing(address recipient, uint256 amount) internal {
    //        underlying.transfer(recipient, amount);
    }
    
    function borrow(uint borrowAmount) external override returns (uint) {
        borrowed[msg.sender] = borrowed[msg.sender].add(borrowAmount);
        _sendUnderlyuing(msg.sender, borrowAmount);
        return NO_ERROR;
    }

    function repayBorrow(uint borrowAmount) external override returns (uint) {
        borrowed[msg.sender] = borrowed[msg.sender].sub(borrowAmount);
        return NO_ERROR;
    }

    function repayBorrowBehalf(address borrower, uint repayAmount) external override returns (uint) {
        borrowed[borrower] = borrowed[borrower].sub(repayAmount);
        return NO_ERROR;
    }

    function liquidateBorrow(address borrower, uint repayAmount, CTokenInterface cTokenCollateral) external override returns (uint) {
         borrowed[borrower] = borrowed[borrower].sub(repayAmount);
        return NO_ERROR;
    }




}