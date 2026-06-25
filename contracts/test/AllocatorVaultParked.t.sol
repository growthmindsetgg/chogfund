// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {LpFixture} from "./AllocatorVaultLp.t.sol";
import {AllocatorVault} from "../src/AllocatorVault.sol";
import {HardenedVault} from "../src/HardenedVault.sol";
import {VaultRouter} from "../src/VaultRouter.sol";
import {MockERC4626Vault} from "../src/MockERC4626Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ----------------- parked fixture (extends the LP fixture) -----------------

contract ParkedFixture is LpFixture {
    VaultRouter vr;
    MockERC4626Vault usdcA;
    MockERC4626Vault usdcB;
    MockERC4626Vault monA;
    MockERC4626Vault monB;

    function _deployParked() internal {
        _deploy();
        vr = new VaultRouter(IERC20(address(usdc)), IERC20(address(wmon)), reader);
        vault.setVaultRouter(vr);
        vr.setVault(address(vault));

        usdcA = new MockERC4626Vault(IERC20(address(usdc)), "USDC Vault A", "uA");
        usdcB = new MockERC4626Vault(IERC20(address(usdc)), "USDC Vault B", "uB");
        monA = new MockERC4626Vault(IERC20(address(wmon)), "MON Vault A", "mA");
        monB = new MockERC4626Vault(IERC20(address(wmon)), "MON Vault B", "mB");

        vr.addUsdcVault(address(usdcA));
        vr.addUsdcVault(address(usdcB)); // backup
        vr.addMonVault(address(monA));
        vr.addMonVault(address(monB));   // backup
    }

    function _accrueUsdcYield(MockERC4626Vault v, uint256 amt) internal {
        usdc.mint(address(this), amt);
        usdc.approve(address(v), amt);
        v.accrueYield(amt);
    }

    function _accrueMonYield(MockERC4626Vault v, uint256 amt) internal {
        vm.deal(address(this), amt);
        wmon.deposit{value: amt}();
        wmon.approve(address(v), amt);
        v.accrueYield(amt);
    }

    function _primeBase() internal {
        _deposit(address(0x1111), 1000e6);
        _rebalanceIntoMon(500e6);
    }

    receive() external payable {}
}

// ----------------- unit tests -----------------

contract AllocatorVaultParkedTest is ParkedFixture {
    function setUp() public { _deployParked(); _seedDeadShares(1e6); }

    function test_ParkUsdc_AccrueYield_Withdraw_NAV() public {
        _deposit(address(0x1111), 1000e6);
        uint256 navBefore = vault.totalAssets();

        uint256 parkAmt = 400e6;
        vm.prank(agent);
        vault.parkUsdc(address(usdcA), parkAmt);

        // NAV conserved on park; parked leg reflects the deposit
        assertApproxEqRel(vault.totalAssets(), navBefore, 1e15);
        (, uint256 parked) = vault.legBreakdown();
        assertApproxEqAbs(parked, parkAmt, 2);
        assertEq(vault.trackedUsdc(), navBefore - parkAmt); // base reduced by parked

        // accrue 10% yield → NAV rises
        _accrueUsdcYield(usdcA, 40e6);
        assertApproxEqAbs(vault.totalAssets(), navBefore + 40e6, 2);

        // unpark all back to base WITH yield
        uint256 shares = vr.sharesOf(address(usdcA));
        uint256 tuBefore = vault.trackedUsdc();
        vm.prank(agent);
        vault.unparkToBase(address(usdcA), shares);
        assertApproxEqAbs(vault.trackedUsdc(), tuBefore + parkAmt + 40e6, 2);
        (, uint256 parkedAfter) = vault.legBreakdown();
        assertEq(parkedAfter, 0);
    }

    function test_ParkMon_AccrueYield_Withdraw_NAV() public {
        _primeBase();
        uint256 navBefore = vault.totalAssets();
        uint256 monPark = vault.trackedMon() / 2;

        vm.prank(agent);
        vault.parkMon(address(monA), monPark);
        assertApproxEqRel(vault.totalAssets(), navBefore, 1e15);

        // accrue MON yield (5% of parked)
        _accrueMonYield(monA, monPark / 20);
        assertGt(vault.totalAssets(), navBefore);

        uint256 shares = vr.sharesOf(address(monA));
        uint256 tmBefore = vault.trackedMon();
        vm.prank(agent);
        vault.unparkToBase(address(monA), shares);
        // recovered principal + yield in native MON terms
        assertApproxEqRel(vault.trackedMon(), tmBefore + monPark + monPark / 20, 1e15);
    }

    function test_Selection_PicksBestNetOfCost() public view {
        address[] memory cands = new address[](2);
        cands[0] = address(usdcA);
        cands[1] = address(usdcB);
        uint256[] memory yields = new uint256[](2);
        yields[0] = 500; // A
        yields[1] = 300; // B
        uint256[] memory costs = new uint256[](2);
        costs[0] = 200; // A net 300
        costs[1] = 50;  // B net 250

        (address best, int256 net) = vr.selectBestVault(cands, yields, costs);
        assertEq(best, address(usdcA), "A should win on net");
        assertEq(net, 300);

        // flip A's cost so B wins on NET despite lower gross yield
        costs[0] = 450; // A net 50
        (best, net) = vr.selectBestVault(cands, yields, costs);
        assertEq(best, address(usdcB), "B should win on net-of-cost");
        assertEq(net, 250);
    }

    function test_CostGate_RejectsBadRotation_AllowsGoodOne() public {
        _deposit(address(0x1111), 1000e6);
        vm.prank(agent);
        vault.parkUsdc(address(usdcA), 400e6);
        uint256 sh = vr.sharesOf(address(usdcA));

        // BAD: candidate yield 450 does NOT beat current 400 by more than 100 cost
        vm.prank(agent);
        vm.expectRevert(AllocatorVault.RotationNotWorthwhile.selector);
        vault.rotateParked(address(usdcA), address(usdcB), sh, 400, 450, 100);
        // funds untouched — no churn
        assertEq(vr.sharesOf(address(usdcA)), sh);
        assertEq(vr.sharesOf(address(usdcB)), 0);

        // GOOD: candidate 600 beats 400 by 200 > 100 cost
        uint256 navBefore = vault.totalAssets();
        vm.prank(agent);
        vault.rotateParked(address(usdcA), address(usdcB), sh, 400, 600, 100);
        assertEq(vr.sharesOf(address(usdcA)), 0);
        assertGt(vr.sharesOf(address(usdcB)), 0);
        // rotation conserved value (mock round-trip ~lossless; real cost at P7)
        assertApproxEqRel(vault.totalAssets(), navBefore, 1e15);
    }

    function test_Whitelist_CannotParkNonWhitelisted() public {
        MockERC4626Vault rogue = new MockERC4626Vault(IERC20(address(usdc)), "Rogue", "RG");
        _deposit(address(0x1111), 1000e6);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(VaultRouter.NotWhitelisted.selector, address(rogue)));
        vault.parkUsdc(address(rogue), 100e6);
    }

    function test_RemovedVault_StillUnwindable() public {
        _deposit(address(0x1111), 1000e6);
        vm.prank(agent);
        vault.parkUsdc(address(usdcA), 300e6);
        // owner de-whitelists A (e.g. it became risky)
        vr.removeVault(address(usdcA));
        // new parks blocked...
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(VaultRouter.NotWhitelisted.selector, address(usdcA)));
        vault.parkUsdc(address(usdcA), 10e6);
        // ...but existing shares still valued + unparkable (funds not stranded)
        (, uint256 parked) = vault.legBreakdown();
        assertApproxEqAbs(parked, 300e6, 2);
        uint256 sh = vr.sharesOf(address(usdcA));
        vm.prank(agent);
        vault.unparkToBase(address(usdcA), sh);
        assertApproxEqAbs(vault.trackedUsdc(), 1e6 + 1000e6, 2);
    }

    function test_Withdraw_UnwindsAllLegs_ProRata() public {
        uint256 s = _deposit(address(0x1111), 1000e6);
        _rebalanceIntoMon(500e6);
        _allocate(vault.trackedMon() / 3, vault.trackedUsdc() / 3);
        uint256 halfU = vault.trackedUsdc() / 2; // evaluate BEFORE vm.prank (else prank is consumed)
        vm.prank(agent);
        vault.parkUsdc(address(usdcA), halfU);
        uint256 halfM = vault.trackedMon() / 2;
        vm.prank(agent);
        vault.parkMon(address(monA), halfM);

        // all four legs now non-trivial
        (uint256 lpv, uint256 parked) = vault.legBreakdown();
        assertGt(lpv, 0);
        assertGt(parked, 0);

        uint256 p = reader.readPriceE8();
        uint256 valueBefore = vault.convertToAssets(s);

        vm.prank(address(0x1111));
        (uint256 usdcOut, uint256 monOut) = vault.redeemInKind(s, address(0x1111));
        uint256 redeemedValue = usdcOut + monOut * p / 1e20;
        // redeemer received their share of base + LP + parked, no leak
        assertApproxEqRel(redeemedValue, valueBefore, 2e16);
    }

    // ----- rotation-decision trace for the report -----
    function test_Trace_RotationGate() public {
        _deposit(address(0x1111), 1000e6);
        vm.prank(agent);
        vault.parkUsdc(address(usdcA), 500e6);

        console2.log("=== P4b ROTATION COST-GATE TRACE ===");
        console2.log("parked 500 USDC in vault A; current expected yield (bps):", uint256(400));

        // scenario 1: marginal candidate — REJECTED
        uint256 candY1 = 450; uint256 cost1 = 100;
        bool ok1 = vr.shouldRotate(400, candY1, cost1);
        console2.log("[reject] candidate yield / round-trip cost (bps):", candY1, cost1);
        console2.log("  net gain = cand - cost - current =", vm.toString(int256(candY1) - int256(cost1) - int256(400)));
        console2.log("  shouldRotate:", ok1);
        uint256 sh = vr.sharesOf(address(usdcA));
        vm.prank(agent);
        vm.expectRevert(AllocatorVault.RotationNotWorthwhile.selector);
        vault.rotateParked(address(usdcA), address(usdcB), sh, 400, candY1, cost1);
        console2.log("  => rotateParked REVERTED (RotationNotWorthwhile); funds stay in A. A shares:", vr.sharesOf(address(usdcA)));

        // scenario 2: clearly better candidate — ALLOWED
        uint256 candY2 = 650; uint256 cost2 = 100;
        bool ok2 = vr.shouldRotate(400, candY2, cost2);
        console2.log("[accept] candidate yield / round-trip cost (bps):", candY2, cost2);
        console2.log("  net gain =", vm.toString(int256(candY2) - int256(cost2) - int256(400)));
        console2.log("  shouldRotate:", ok2);
        uint256 navBefore = vault.totalAssets();
        vm.prank(agent);
        vault.rotateParked(address(usdcA), address(usdcB), sh, 400, candY2, cost2);
        console2.log("  => rotated A->B. A shares:", vr.sharesOf(address(usdcA)), " B shares:", vr.sharesOf(address(usdcB)));
        console2.log("  NAV before/after rotation (6d):", navBefore, vault.totalAssets());
    }
}

// ----------------- invariant suite -----------------

contract ParkedHandler is ParkedFixture {
    function setUpHandler() external { _deployParked(); _seedDeadShares(1e6); }

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

    function allocateLp(uint256 m, uint256 u) public {
        uint256 tm = vault.trackedMon();
        uint256 tu = vault.trackedUsdc();
        if (tm < 1e15 || tu < 2e6) return;
        m = bound(m, 1e14, tm);
        u = bound(u, 1e6, tu);
        try this.extAllocate(m, u) {} catch {}
    }
    function extAllocate(uint256 m, uint256 u) external { _allocate(m, u); }

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

    function accrue(uint256 amt) public {
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

contract AllocatorVaultParkedInvariants is Test {
    ParkedHandler handler;
    AllocatorVault vault;

    function setUp() public {
        handler = new ParkedHandler();
        handler.setUpHandler();
        vault = handler.vault();

        bytes4[] memory sel = new bytes4[](8);
        sel[0] = handler.deposit.selector;
        sel[1] = handler.rebalance.selector;
        sel[2] = handler.allocateLp.selector;
        sel[3] = handler.parkUsdc.selector;
        sel[4] = handler.parkMon.selector;
        sel[5] = handler.rotate.selector;
        sel[6] = handler.accrue.selector;
        sel[7] = handler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    // INV: base solvency — the vault holds at least its tracked BASE assets
    // (legs hold the rest; base claims must be payable at all times).
    function invariant_BaseSolvency() public view {
        assertGe(handler.usdc().balanceOf(address(vault)), vault.trackedUsdc());
        assertGe(address(vault).balance, vault.trackedMon());
    }

    // INV: NAV sums all legs (base USDC + base MON + LP + parked) exactly once.
    function invariant_NavSumsAllLegsOnce() public view {
        (uint256 baseUsdc, uint256 baseMonValue, uint256 legs, uint256 total) = vault.navBreakdown();
        assertEq(baseUsdc + baseMonValue + legs, total);
        assertEq(total, vault.totalAssets());
        (uint256 lpv, uint256 parked) = vault.legBreakdown();
        assertEq(lpv + parked, legs); // legs split with no double-count / dropped leg
    }

    function invariant_NoUnbackedShares() public view {
        if (vault.totalSupply() > 0) assertGt(vault.totalAssets(), 0);
    }
}
