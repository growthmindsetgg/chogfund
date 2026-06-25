// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockERC4626Vault
/// @notice ====================  MOCK  ====================
///         A FAITHFUL ERC4626 (OpenZeppelin base) used as a parked-yield venue.
///         deposit / mint / withdraw / redeem / previewRedeem / convertTo* are the
///         REAL audited OZ implementations — so the parked-share VALUE path
///         (previewRedeem) is canary-faithful. The ONLY mock surface is yield
///         injection: `accrueYield` transfers underlying INTO the vault, raising
///         assets-per-share exactly as real yield would. Real vault behavior
///         (strategy returns, withdrawal queues, fees) is validated at the P7
///         mainnet canary. P4c adds settable stress signals on top of this.
contract MockERC4626Vault is ERC4626 {
    constructor(IERC20 asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
    {}

    /// @notice MOCK: simulate yield by funding the vault with extra underlying,
    ///         which lifts totalAssets() → previewRedeem() for all shareholders.
    ///         Caller must approve this vault for `amount` of the underlying.
    function accrueYield(uint256 amount) external {
        IERC20(asset()).transferFrom(msg.sender, address(this), amount);
    }
}
