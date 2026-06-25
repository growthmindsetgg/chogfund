// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHealthSignals} from "./HealthMonitor.sol";

/// @title MockERC4626Vault
/// @notice ====================  MOCK  ====================
///         A FAITHFUL ERC4626 (OpenZeppelin base) used as a parked-yield venue.
///         deposit / mint / withdraw / redeem / previewRedeem / convertTo* are the
///         REAL audited OZ implementations — so the parked-share VALUE path
///         (previewRedeem) is canary-faithful. Mock surfaces:
///           * `accrueYield` — funds the vault to lift assets/share (real yield).
///           * `slashValue`  — removes underlying to drop assets/share (real loss).
///           * settable STRESS signals (utilization, deposit pause, peg) read by the
///             HealthMonitor to drive the graduated emergency-exit policy.
///         On the real protocol these signals come from a per-protocol adapter
///         implementing IHealthSignals; the value/withdraw behavior is validated at
///         the P7 mainnet canary.
contract MockERC4626Vault is ERC4626, IHealthSignals {
    // ----- settable stress signals (default = perfectly healthy) -----
    uint256 private _utilizationBps;     // 0..10000, withdraw-risk proxy
    bool private _depositsPaused;        // guardian / protocol pause
    uint256 private _pegBps = 10_000;    // 10000 = perfect peg; lower = share-price/peg drop

    address private constant SINK = 0x000000000000000000000000000000000000dEaD;

    event StressSet(uint256 utilizationBps, bool depositsPaused, uint256 pegBps);
    event ValueSlashed(uint256 amount);

    error DepositsPaused();

    constructor(IERC20 asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
    {}

    // ----- yield / loss simulation -----

    /// @notice MOCK: simulate yield by funding the vault (lifts previewRedeem).
    function accrueYield(uint256 amount) external {
        IERC20(asset()).transferFrom(msg.sender, address(this), amount);
    }

    /// @notice MOCK: simulate a loss / share-price drop by removing underlying.
    function slashValue(uint256 amount) external {
        IERC20(asset()).transfer(SINK, amount);
        emit ValueSlashed(amount);
    }

    // ----- stress controls + IHealthSignals -----

    function setStress(uint256 utilizationBps_, bool depositsPaused_, uint256 pegBps_) external {
        _utilizationBps = utilizationBps_;
        _depositsPaused = depositsPaused_;
        _pegBps = pegBps_;
        emit StressSet(utilizationBps_, depositsPaused_, pegBps_);
    }

    function utilizationBps() external view override returns (uint256) { return _utilizationBps; }
    function depositsPaused() external view override returns (bool) { return _depositsPaused; }
    function pegBps() external view override returns (uint256) { return _pegBps; }

    /// @dev A paused venue rejects NEW deposits (faithful: you cannot add to a paused
    ///      protocol) but still allows redemptions, so an emergency exit can recover
    ///      funds. (A vault that also freezes withdrawals is the worst case — that is
    ///      precisely why CAUTION stops adding early. Flagged for the P7 canary.)
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (_depositsPaused) revert DepositsPaused();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        if (_depositsPaused) revert DepositsPaused();
        return super.mint(shares, receiver);
    }
}
