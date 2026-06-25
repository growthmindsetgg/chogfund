// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SafetyFixture} from "./AllocatorVaultSafety.t.sol";
import {AllocatorVault} from "../src/AllocatorVault.sol";
import {MockERC4626Vault} from "../src/MockERC4626Vault.sol";
import {TickMath} from "../src/external/uniswap/TickMath.sol";
import {LiquidityAmounts} from "../src/external/uniswap/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// Comprehensive harness: exercises EVERY allocator action (deposit, rebalance,
/// allocate LP, shift range, move market, park USDC/MON, rotate, stress, flee,
/// emergency, accrue fees/yield, redeem) and exposes an INDEPENDENT NAV computed
/// purely from externally-observed state — it never calls the contract's
/// _legsValueUsdc / navBreakdown / totalAssets for any leg.
contract NavHandler is SafetyFixture {
    int24 constant LP_WIDTH = 6000;

    function setUpHandler() external { _deploySafety(); _seedDeadShares(1e6); }

    // ---------------- INDEPENDENT NAV (test-side, no contract NAV calls) ----------------

    /// @notice NAV recomputed from raw external state. Mirrors the contract's leg
    ///         GROUPING (three separate MON->USDC conversions: base, LP, parked) so any
    ///         difference is a genuine accounting discrepancy, not a grouping artifact.
    function independentNav() external view returns (uint256) {
        uint256 price = reader.readPriceE8(); // price source read DIRECTLY

        // base = physical balances actually held by the vault (NOT trackedUsdc/Mon)
        uint256 baseUsdc = IERC20(address(usdc)).balanceOf(address(vault));
        uint256 baseMonVal = address(vault).balance * price / 1e20;

        (uint256 lpUsdc, uint256 lpWmon) = _lpAmounts();
        uint256 lpVal = lpUsdc + lpWmon * price / 1e20;

        (uint256 parkedUsdc, uint256 parkedWmon) = _parkedAmounts();
        uint256 parkedVal = parkedUsdc + parkedWmon * price / 1e20;

        return baseUsdc + baseMonVal + lpVal + parkedVal;
    }

    /// @dev LP token0/token1 amounts re-derived in the test from the mock pool's
    ///      slot0 sqrtPriceX96 + the position's liquidity/ticks via the SAME audited
    ///      Uniswap libs, called here independently (not through LpManager.valueUsdc).
    function _lpAmounts() internal view returns (uint256 usdcAmt, uint256 wmonAmt) {
        uint256 tid = lp.tokenId();
        if (tid == 0) return (0, 0);
        (, , , , , int24 tl, int24 tu, uint128 liq, , , uint128 owed0, uint128 owed1) = npm.positions(tid);
        (uint160 sp, , , , , , ) = pool.slot0();
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            sp, TickMath.getSqrtRatioAtTick(tl), TickMath.getSqrtRatioAtTick(tu), liq
        );
        uint256 t0 = amt0 + owed0;
        uint256 t1 = amt1 + owed1;
        (wmonAmt, usdcAmt) = usdcIsToken0 ? (t1, t0) : (t0, t1);
    }

    /// @dev Parked underlying via previewRedeem(sharesHeld) over EVERY known venue.
    function _parkedAmounts() internal view returns (uint256 usdcAssets, uint256 wmonAssets) {
        usdcAssets = IERC4626(address(usdcA)).previewRedeem(usdcA.balanceOf(address(vr)))
            + IERC4626(address(usdcB)).previewRedeem(usdcB.balanceOf(address(vr)));
        wmonAssets = IERC4626(address(monA)).previewRedeem(monA.balanceOf(address(vr)))
            + IERC4626(address(monB)).previewRedeem(monB.balanceOf(address(vr)));
    }

    // ---------------- handler actions ----------------

    function deposit(uint256 amt) public {
        amt = bound(amt, 1e6, 1e14);
        address a = address(0xB1);
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(vault), amt);
        try vault.deposit(amt, a) {} catch {}
        vm.stopPrank();
    }

    function rebalance(uint256 amt) public {
        uint256 tu = vault.trackedUsdc();
        if (tu < 2e6) return;
        amt = bound(amt, 1e6, tu / 2);
        try this.extRebalance(amt) {} catch {}
    }
    function extRebalance(uint256 amt) external { _rebalanceIntoMon(amt); }

    function allocate(uint256 m, uint256 u) public {
        if (vault.trackedMon() < 1e15 || vault.trackedUsdc() < 2e6) return;
        m = bound(m, 1e14, vault.trackedMon());
        u = bound(u, 1e6, vault.trackedUsdc());
        try this.extAllocate(m, u) {} catch {}
    }
    function extAllocate(uint256 m, uint256 u) external { _allocate(m, u); }

    function shift(uint256 seed) public {
        if (lp.tokenId() == 0) return;
        int24 w = int24(int256(bound(seed, 1800, 9000)) / 60 * 60);
        (, int24 tick, , , , , ) = pool.slot0();
        int24 c = (tick / 60) * 60;
        vm.prank(agent);
        try vault.shiftLpRange(c - w, c + w) {} catch {}
    }

    function moveMarket(uint256 seed) public {
        int24 delta = int24(int256(bound(seed, 0, 8000)) - 4000);
        try this.extMove(centerTick + delta) {} catch {}
    }
    function extMove(int24 t) external { _setMarketTick(t); }

    function parkUsdc(uint256 amt) public {
        uint256 tu = vault.trackedUsdc();
        if (tu < 2e6) return;
        amt = bound(amt, 1e6, tu);
        vm.prank(agent);
        try vault.parkUsdc(address(usdcA), amt) {} catch {}
    }

    function parkMon(uint256 amt) public {
        uint256 tm = vault.trackedMon();
        if (tm < 1e15) return;
        amt = bound(amt, 1e14, tm);
        vm.prank(agent);
        try vault.parkMon(address(monA), amt) {} catch {}
    }

    function rotate(uint256 candY) public {
        uint256 sh = vr.sharesOf(address(usdcA));
        if (sh == 0) return;
        candY = bound(candY, 0, 2000);
        vm.prank(agent);
        try vault.rotateParked(address(usdcA), address(usdcB), sh, 400, candY, 100) {} catch {}
    }

    function stressA(uint256 util, uint256 pegSeed, uint256 pauseSeed) public {
        usdcA.setStress(bound(util, 0, 10_000), pauseSeed % 6 == 0, bound(pegSeed, 8000, 10_000));
    }

    function flee(uint256) public {
        uint256 sh = vr.sharesOf(address(usdcA));
        if (sh == 0) return;
        vm.prank(agent);
        try vault.fleeToBackup(address(usdcA), address(usdcB), sh) {} catch {}
    }

    function emergency(uint256 which) public {
        address v = which % 2 == 0 ? address(usdcA) : address(usdcB);
        vm.prank(agent);
        try vault.emergencyExitAll(v) {} catch {}
    }

    function accrueLpFees(uint256 f) public {
        if (lp.tokenId() == 0) return;
        f = bound(f, 0, 1e7);
        (uint128 a, uint128 b) = usdcIsToken0 ? (uint128(f), uint128(f * 1e9)) : (uint128(f * 1e9), uint128(f));
        try npm.accrueFees(lp.tokenId(), a, b) {} catch {}
    }

    function accrueYield(uint256 amt) public {
        amt = bound(amt, 0, 1e9);
        usdc.mint(address(this), amt);
        usdc.approve(address(usdcA), amt);
        try usdcA.accrueYield(amt) {} catch {}
    }

    function redeem(uint256 sharesSeed) public {
        uint256 bal = vault.balanceOf(address(0xB1));
        if (bal == 0) return;
        uint256 sh = bound(sharesSeed, 1, bal);
        vm.prank(address(0xB1));
        try vault.redeemInKind(sh, address(0xB1)) {} catch {}
    }
}

// ------------------------------- invariant suite -------------------------------

contract AllocatorVaultNavInvariants is Test {
    NavHandler handler;
    AllocatorVault vault;

    // Tolerance: base USDC/MON are read from the vault's PHYSICAL balances, which equal
    // the contract's internal base accounting across every operation (balanceOf == tracked
    // is preserved by every park/allocate/rotate/flee/redeem path). The LP and parked legs
    // are re-derived with the identical audited library calls (getAmountsForLiquidity /
    // previewRedeem), same operands, and the SAME three-separate-MON->USDC-division grouping
    // as the contract. The mathematically-expected difference is therefore 0; TOL_USDC6 is a
    // defensive margin for at most a couple of single-unit (1e-6 USDC) integer-division
    // truncations. It is ~5 orders of magnitude below any single leg's value in these runs,
    // so a leg counted twice (which inflates NAV by an entire leg) is always caught.
    uint256 constant TOL_USDC6 = 5; // 5e-6 USDC

    function setUp() public {
        handler = new NavHandler();
        handler.setUpHandler();
        vault = handler.vault();

        bytes4[] memory sel = new bytes4[](14);
        sel[0] = handler.deposit.selector;
        sel[1] = handler.rebalance.selector;
        sel[2] = handler.allocate.selector;
        sel[3] = handler.shift.selector;
        sel[4] = handler.moveMarket.selector;
        sel[5] = handler.parkUsdc.selector;
        sel[6] = handler.parkMon.selector;
        sel[7] = handler.rotate.selector;
        sel[8] = handler.stressA.selector;
        sel[9] = handler.flee.selector;
        sel[10] = handler.emergency.selector;
        sel[11] = handler.accrueLpFees.selector;
        sel[12] = handler.accrueYield.selector;
        sel[13] = handler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// INDEPENDENT NAV CHECK: the contract's totalAssets() must equal a NAV recomputed
    /// entirely outside the contract's own leg-valuation code, after EVERY handler action.
    /// This catches a bug inside _legsValueUsdc (double-count, dropped leg, mis-mapped
    /// token) that the existing navBreakdown()==totalAssets() guard cannot.
    function invariant_TotalAssetsEqualsIndependentNav() public view {
        assertApproxEqAbs(vault.totalAssets(), handler.independentNav(), TOL_USDC6);
    }
}

// ------------------------------- tolerance calibration -------------------------------

contract NavCalibration is SafetyFixture {
    function setUp() public { _deploySafety(); _seedDeadShares(1e6); }

    function _diff() internal view returns (uint256) {
        // independent NAV inlined here (same logic as NavHandler.independentNav)
        uint256 price = reader.readPriceE8();
        uint256 baseUsdc = IERC20(address(usdc)).balanceOf(address(vault));
        uint256 baseMonVal = address(vault).balance * price / 1e20;
        uint256 lpVal;
        if (lp.tokenId() != 0) {
            (, , , , , int24 tl, int24 tu, uint128 liq, , , uint128 o0, uint128 o1) = npm.positions(lp.tokenId());
            (uint160 sp, , , , , , ) = pool.slot0();
            (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
                sp, TickMath.getSqrtRatioAtTick(tl), TickMath.getSqrtRatioAtTick(tu), liq
            );
            (uint256 w, uint256 u) = usdcIsToken0 ? (a1 + o1, a0 + o0) : (a0 + o0, a1 + o1);
            lpVal = u + w * price / 1e20;
        }
        uint256 pu = IERC4626(address(usdcA)).previewRedeem(usdcA.balanceOf(address(vr)));
        uint256 pw = IERC4626(address(monA)).previewRedeem(monA.balanceOf(address(vr)));
        uint256 parkedVal = pu + pw * price / 1e20;
        uint256 indep = baseUsdc + baseMonVal + lpVal + parkedVal;
        uint256 ta = vault.totalAssets();
        return ta > indep ? ta - indep : indep - ta;
    }

    function test_Calibrate_AllLegsLive() public {
        _deposit(address(0x1111), 1000e6);
        _rebalanceIntoMon(400e6);
        _allocate(vault.trackedMon() / 2, vault.trackedUsdc() / 4);
        uint256 up = vault.trackedUsdc() / 3; // evaluate BEFORE vm.prank
        vm.prank(agent); vault.parkUsdc(address(usdcA), up);
        uint256 mp = vault.trackedMon() / 2;
        vm.prank(agent); vault.parkMon(address(monA), mp);
        npm.accrueFees(lp.tokenId(), usdcIsToken0 ? uint128(2e6) : uint128(1e17), usdcIsToken0 ? uint128(1e17) : uint128(2e6));
        usdc.mint(address(this), 3e6); usdc.approve(address(usdcA), 3e6); usdcA.accrueYield(3e6);
        console2.log("diff @ all-legs-live (in-range), micro-USDC:", _diff());
        _setMarketTick(centerTick + 5000); // push LP out of range
        console2.log("diff @ all-legs-live (out-of-range)      :", _diff());
        assertLe(_diff(), 5);
    }
}
