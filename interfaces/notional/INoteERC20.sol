// SPDX-License-Identifier: BSUL-1.1
pragma solidity >=0.7.6;

interface INoteERC20 {
    function symbol() external view returns (string memory);
    function getPriorVotes(address account, uint256 blockNumber) external view returns (uint96);
}
