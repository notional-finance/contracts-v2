
// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../global/StorageLayoutV2.sol";
import "../../proxy/utils/UUPSUpgradeable.sol";
import "interfaces/notional/NotionalTreasury.sol";

interface Comptroller {
    function claimComp(address holder) external;
}

contract TreasuryAction is StorageLayoutV2, NotionalTreasury, UUPSUpgradeable {
    IERC20 public immutable COMP;
    Comptroller public immutable COMPTROLLER;


    /// @dev Throws if called by any account other than the owner.
    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    modifier onlyTreasuryManager() {
        require(treasuryManager == msg.sender, "Ownable: caller is not the treasury manager");
        _;
    }

    constructor(IERC20 comp_, Comptroller comptroller_) {
        COMP = comp_;
        COMPTROLLER = comptroller_;
        treasuryManager = address(0);
    }

    function claimCOMP() external override onlyTreasuryManager returns (uint256) {
        COMPTROLLER.claimComp(address(this));
        uint256 bal = COMP.balanceOf(address(this));
        COMP.transfer(treasuryManager, bal);
        return bal;
    }

    function setTreasuryManager(address manager) external override onlyOwner {
        treasuryManager = manager;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
