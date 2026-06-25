// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HardenedVault, ILogBook} from "./HardenedVault.sol";
import {PythPriceReader} from "./PythPriceReader.sol";
import {LpManager} from "./LpManager.sol";

interface IWMON {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title AllocatorVault — P4 yield strategy on top of the hardened P3 core.
/// @notice Extends HardenedVault with the first allocator leg: a MON/USDC
///         concentrated-liquidity position managed by LpManager. Carries over every
///         P3 guarantee and adds:
///           * NAV sums all legs exactly once (base MON + base USDC + LP leg) via the
///             `_legsValueUsdc` hook → share price reflects the LP position.
///           * Redemption is still in-kind and pro-rata: `_unwindLegs` pulls the
///             redeemer's fraction of the LP leg back into base MON+USDC.
///           * The agent can ONLY allocate / shift — never withdraw to a non-vault
///             address. The LpManager is an owner/human-set whitelist entry; the
///             agent cannot change it. Every LP action writes a LogBook entry.
///           * Allocation/shift slippage is enforced as a Pyth-anchored NAV check:
///             navAfter >= navBefore * (1 - slippageBps). Because LpManager sweeps
///             un-deployed tokens back losslessly, this NAV-conservation guard is a
///             stronger protection than per-token amountMin floors and also catches a
///             manipulated pool price (the LP leg is valued at the trustless Pyth
///             price, so a divergent pool ratio trips the check). Real per-token
///             Uniswap mins are revisited at the P7 mainnet canary.
contract AllocatorVault is HardenedVault {
    using SafeERC20 for IERC20;

    IWMON public immutable wmon;
    LpManager public lpManager;

    event LpManagerSet(address indexed lpManager);
    event AllocatedToLp(uint256 priceE8, uint256 monIn, uint256 usdcIn, int24 tickLower, int24 tickUpper, uint256 navBefore, uint256 navAfter);
    event LpRangeShifted(uint256 priceE8, int24 tickLower, int24 tickUpper, uint256 navBefore, uint256 navAfter);
    event LpFeesCollected(uint256 wmonToBase, uint256 usdcToBase);

    error LpManagerAlreadySet();
    error LpManagerUnset();
    error AllocSlippage(uint256 navAfter, uint256 floor);

    constructor(
        IERC20 usdcToken,
        PythPriceReader _priceReader,
        ILogBook _logBook,
        address _agent,
        uint256 _slippageBps,
        IWMON _wmon
    ) HardenedVault(usdcToken, _priceReader, _logBook, _agent, _slippageBps) {
        wmon = _wmon;
    }

    /// @notice One-time wiring of the LP leg (owner/human whitelist action).
    function setLpManager(LpManager _lp) external onlyOwner {
        if (address(lpManager) != address(0)) revert LpManagerAlreadySet();
        require(address(_lp) != address(0), "vault: zero lp");
        lpManager = _lp;
        emit LpManagerSet(address(_lp));
    }

    // ============================ leg hooks (override P3 defaults) ============================

    function _legsValueUsdc() internal view override returns (uint256) {
        LpManager lp = lpManager;
        if (address(lp) == address(0)) return 0;
        return lp.valueUsdc();
    }

    /// @dev Pull `shares/supply` of the LP leg back into the vault, returning the
    ///      proceeds as (USDC, native MON) to be forwarded to the redeemer.
    function _unwindLegs(uint256 shares, uint256 supply)
        internal
        override
        returns (uint256 usdcFromLegs, uint256 monFromLegs)
    {
        LpManager lp = lpManager;
        if (address(lp) == address(0) || lp.tokenId() == 0) return (0, 0);
        (uint256 wmonOut, uint256 usdcOut) = lp.unwind(shares, supply); // sends WMON + USDC here
        if (wmonOut > 0) wmon.withdraw(wmonOut);                        // WMON → native MON
        return (usdcOut, wmonOut);                                      // 1:1 WMON↔MON
    }

    // ============================ agent: allocate to LP ============================

    /// @notice Agent deploys `monAmount` (native) + `usdcAmount` of the vault's BASE
    ///         assets into a MON/USDC LP position at [tickLower, tickUpper].
    ///         Amounts must come from tracked base (never donations). Un-deployed dust
    ///         is swept back and re-tracked; NAV is conserved within the slippage cap.
    function allocateToLp(
        uint256 monAmount,
        uint256 usdcAmount,
        int24 tickLower,
        int24 tickUpper
    ) external onlyAgent nonReentrant {
        if (paused) revert Paused();
        if (address(lpManager) == address(0)) revert LpManagerUnset();
        if (monAmount > _trackedMon) revert AmountExceedsTracked();
        if (usdcAmount > _trackedUsdc) revert AmountExceedsTracked();

        uint256 p = priceReader.readPriceE8();
        uint256 navBefore = totalAssets();

        // _deployToLp moves base→LP and returns the NET-deployed amounts (dust swept
        // back & re-tracked inside). Scoped in its own frame to bound stack depth.
        (uint256 monDeployed, uint256 usdcDeployed) =
            _deployToLp(monAmount, usdcAmount, tickLower, tickUpper);

        uint256 navAfter = totalAssets();
        if (navAfter < navBefore * (10_000 - slippageBps) / 10_000) {
            revert AllocSlippage(navAfter, navBefore * (10_000 - slippageBps) / 10_000);
        }

        logBook.record(p, _monBps(p, navBefore), _monBps(p, navAfter), navBefore, navAfter);
        emit AllocatedToLp(p, monDeployed, usdcDeployed, tickLower, tickUpper, navBefore, navAfter);
    }

    /// @dev Wrap + push + mint/increase, then reconcile tracked accounting against the
    ///      NET amount actually deployed (un-deployed dust is unwrapped/kept tracked).
    function _deployToLp(uint256 monAmount, uint256 usdcAmount, int24 tickLower, int24 tickUpper)
        internal
        returns (uint256 monDeployed, uint256 usdcDeployed)
    {
        uint256 usdcBalBefore = IERC20(asset()).balanceOf(address(this));

        wmon.deposit{value: monAmount}();
        IERC20(address(wmon)).safeTransfer(address(lpManager), monAmount);
        if (usdcAmount > 0) IERC20(asset()).safeTransfer(address(lpManager), usdcAmount);

        // mins handled by the NAV-conservation guard in the caller (see contract notes).
        if (lpManager.tokenId() == 0) {
            lpManager.openPosition(monAmount, usdcAmount, tickLower, tickUpper, 0, 0);
        } else {
            lpManager.increasePosition(monAmount, usdcAmount, 0, 0);
        }

        uint256 leftoverWmon = IERC20(address(wmon)).balanceOf(address(this));
        if (leftoverWmon > 0) wmon.withdraw(leftoverWmon); // back to native, stays tracked
        monDeployed = monAmount - leftoverWmon;
        usdcDeployed = usdcBalBefore - IERC20(asset()).balanceOf(address(this));

        _trackedMon  -= monDeployed;
        _trackedUsdc -= usdcDeployed;
    }

    // ============================ agent: shift range ============================

    /// @notice Agent re-centers the LP range. Closes + reopens at the new ticks;
    ///         value conserved within the slippage cap. Swept dust re-tracked.
    function shiftLpRange(int24 tickLower, int24 tickUpper) external onlyAgent nonReentrant {
        if (paused) revert Paused();
        if (address(lpManager) == address(0) || lpManager.tokenId() == 0) revert LpManagerUnset();

        uint256 p = priceReader.readPriceE8();
        uint256 navBefore = totalAssets();
        uint256 usdcBalBefore = IERC20(asset()).balanceOf(address(this));

        lpManager.shiftRange(tickLower, tickUpper, 0, 0); // sweeps leftovers here

        uint256 leftoverWmon = IERC20(address(wmon)).balanceOf(address(this));
        if (leftoverWmon > 0) wmon.withdraw(leftoverWmon);
        _trackedMon += leftoverWmon;

        uint256 usdcBalAfter = IERC20(asset()).balanceOf(address(this));
        if (usdcBalAfter > usdcBalBefore) _trackedUsdc += (usdcBalAfter - usdcBalBefore);

        uint256 navAfter = totalAssets();
        uint256 floor = navBefore * (10_000 - slippageBps) / 10_000;
        if (navAfter < floor) revert AllocSlippage(navAfter, floor);

        uint256 bps = _monBps(p, navAfter);
        logBook.record(p, _monBps(p, navBefore), bps, navBefore, navAfter);
        emit LpRangeShifted(p, tickLower, tickUpper, navBefore, navAfter);
    }

    // ============================ agent: collect fees to base ============================

    /// @notice Agent harvests LP fees back into the vault's base assets (re-tracked).
    function collectLpFees() external onlyAgent nonReentrant {
        if (address(lpManager) == address(0) || lpManager.tokenId() == 0) revert LpManagerUnset();
        uint256 usdcBalBefore = IERC20(asset()).balanceOf(address(this));

        (uint256 wmonOut, ) = lpManager.collectFees(); // sends WMON + USDC here

        if (wmonOut > 0) wmon.withdraw(wmonOut);
        _trackedMon += wmonOut;

        uint256 usdcBalAfter = IERC20(asset()).balanceOf(address(this));
        uint256 usdcToBase = usdcBalAfter - usdcBalBefore;
        _trackedUsdc += usdcToBase;

        emit LpFeesCollected(wmonOut, usdcToBase);
    }

    // ============================ views / tracing ============================

    /// @notice MON value as a fraction of NAV (bps), counting base MON + LP MON.
    function _monBps(uint256 p, uint256 nav) internal view returns (uint256) {
        if (nav == 0) return 0;
        uint256 monVal = _trackedMon * p / 1e20;
        LpManager lp = lpManager;
        if (address(lp) != address(0) && lp.tokenId() != 0) {
            (, uint256 wmonAmt, , uint256 wmonFees, ) = lp.positionAmounts();
            monVal += (wmonAmt + wmonFees) * p / 1e20;
        }
        return monVal * 10_000 / nav;
    }

    /// @notice NAV breakdown for off-chain tracing: (baseUsdc, baseMonValue, lpValue, total).
    function navBreakdown()
        external
        view
        returns (uint256 baseUsdc, uint256 baseMonValue, uint256 lpValue, uint256 total)
    {
        baseUsdc = _trackedUsdc;
        uint256 p = priceReader.readPriceE8();
        baseMonValue = _trackedMon * p / 1e20;
        lpValue = _legsValueUsdc();
        total = baseUsdc + baseMonValue + lpValue;
    }
}
