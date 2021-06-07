pragma solidity ^0.7.0;

interface INoteERC20 {
    function getPriorVotes(address account, uint256 blockNumber) external view returns (uint96);
}
