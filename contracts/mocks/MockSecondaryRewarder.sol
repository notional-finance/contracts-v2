
contract MockSecondaryRewarder {

    event ClaimRewards(address account, uint256 nTokenBalanceBefore, uint256 nTokenBalanceAfter, uint256 NOTETokensClaimed);

    function claimRewards(
        address account,
        uint256 nTokenBalanceBefore,
        uint256 nTokenBalanceAfter,
        uint256 NOTETokensClaimed
    ) external {
        emit ClaimRewards(account, nTokenBalanceBefore, nTokenBalanceAfter, NOTETokensClaimed);
    }

}