// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ParkedFixture} from "./AllocatorVaultParked.t.sol";
import {AllocatorVault} from "../src/AllocatorVault.sol";
import {VaultRouter} from "../src/VaultRouter.sol";
import {HealthMonitor} from "../src/HealthMonitor.sol";
import {MockERC4626Vault} from "../src/MockERC4626Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ----------------- safety fixture (extends parked fixture + a HealthMonitor) -----------------

contract SafetyFixture is ParkedFixture {
    HealthMonitor monitor;

    // thresholds: caution util>=7000 ; stress util>=9000 OR peg<=9700 ; emergency pause OR peg<=9000
    function _deploySafety() internal {
        _deployParked();
        monitor = new HealthMonitor(7000, 9000, 9700, 9000);
        vault.setHealthMonitor(monitor);
    }

    function _stress(MockERC4626Vault v, uint256 util, bool paused, uint256 peg) internal {
        v.setStress(util, paused, peg);
    }
}

// ----------------- unit tests -----------------

contract AllocatorVaultSafetyTest is SafetyFixture {
    function setUp() public { _deploySafety(); _seedDeadShares(1e6); }

    function test_Caution_StopsAdding() public {
        _deposit(address(0x1111), 1000e6);
        // healthy → park ok
        vm.prank(agent);
        vault.parkUsdc(address(usdcA), 100e6);

        // raise utilization into CAUTION band → further adds blocked
        _stress(usdcA, 7500, false, 10_000);
        assertEq(uint8(monitor.tierOf(address(usdcA))), uint8(HealthMonitor.Tier.CAUTION));
        vm.prank(agent);
        vm.expectRevert(AllocatorVault.StopAdding.selector);
        vault.parkUsdc(address(usdcA), 50e6);

        // a still-healthy backup remains addable
        vm.prank(agent);
        vault.parkUsdc(address(usdcB), 50e6);
    }

    function test_Stress_FleePrimaryToBackup() public {
        _deposit(address(0x1111), 1000e6);
        vm.prank(agent);
        vault.parkUsdc(address(usdcA), 400e6);
        uint256 sh = vr.sharesOf(address(usdcA));
        uint256 navBefore = vault.totalAssets();

        // primary enters STRESS (withdraw-at-risk utilization)
        _stress(usdcA, 9500, false, 10_000);
        assertEq(uint8(monitor.tierOf(address(usdcA))), uint8(HealthMonitor.Tier.STRESS));

        uint256 logsBefore = logbook.count();
        vm.prank(agent);
        vault.fleeToBackup(address(usdcA), address(usdcB), sh);

        assertEq(vr.sharesOf(address(usdcA)), 0, "primary not emptied");
        assertGt(vr.sharesOf(address(usdcB)), 0, "backup not funded");
        assertApproxEqRel(vault.totalAssets(), navBefore, 1e15); // value conserved
        assertEq(logbook.count(), logsBefore + 1, "flee not logged");
    }

    function test_Stress_RefusesFleeIntoUnsafeBackup() public {
        _deposit(address(0x1111), 1000e6);
        vm.prank(agent);
        vault.parkUsdc(address(usdcA), 400e6);
        uint256 sh = vr.sharesOf(address(usdcA));

        _stress(usdcA, 9500, false, 10_000); // primary STRESS
        _stress(usdcB, 0, true, 10_000);     // backup EMERGENCY (paused)

        vm.prank(agent);
        vm.expectRevert(AllocatorVault.BackupUnsafe.selector);
        vault.fleeToBackup(address(usdcA), address(usdcB), sh);
    }

    function test_Emergency_PullAllToBase_OnPause() public {
        _deposit(address(0x1111), 1000e6);
        _rebalanceIntoMon(500e6);
        uint256 uPark = vault.trackedUsdc() / 2;
        vm.prank(agent);
        vault.parkUsdc(address(usdcA), uPark);
        uint256 mPark = vault.trackedMon() / 2;
        vm.prank(agent);
        vault.parkMon(address(monA), mPark);

        uint256 navBefore = vault.totalAssets();
        (, uint256 parkedBefore) = vault.legBreakdown();
        assertGt(parkedBefore, 0);

        // usdcA gets paused → EMERGENCY
        _stress(usdcA, 0, true, 10_000);
        assertEq(uint8(monitor.tierOf(address(usdcA))), uint8(HealthMonitor.Tier.EMERGENCY));

        uint256 logsBefore = logbook.count();
        vm.prank(agent);
        vault.emergencyExitAll(address(usdcA));

        (, uint256 parkedAfter) = vault.legBreakdown();
        assertEq(parkedAfter, 0, "parked not fully pulled to base");
        assertEq(vr.sharesOf(address(usdcA)), 0);
        assertEq(vr.sharesOf(address(monA)), 0);
        assertApproxEqRel(vault.totalAssets(), navBefore, 1e15); // no value lost in the flee
        assertEq(logbook.count(), logsBefore + 1, "emergency not logged");
    }

    function test_Emergency_OnDepeg_NavReflectsLoss() public {
        _deposit(address(0x1111), 1000e6);
        vm.prank(agent);
        vault.parkUsdc(address(usdcA), 400e6);
        uint256 navHealthy = vault.totalAssets();

        // real loss: slash 10% of the venue's underlying → previewRedeem drops
        usdcA.slashValue(40e6);
        // and the peg signal trips EMERGENCY
        _stress(usdcA, 0, false, 8500);
        assertEq(uint8(monitor.tierOf(address(usdcA))), uint8(HealthMonitor.Tier.EMERGENCY));

        uint256 navDepeg = vault.totalAssets();
        assertApproxEqAbs(navDepeg, navHealthy - 40e6, 2, "NAV did not reflect the loss");

        // emergency-exit recovers the REDUCED value to base (no further loss)
        vm.prank(agent);
        vault.emergencyExitAll(address(usdcA));
        (, uint256 parkedAfter) = vault.legBreakdown();
        assertEq(parkedAfter, 0);
        assertApproxEqAbs(vault.totalAssets(), navDepeg, 2);
    }

    function test_FleeToNonWhitelisted_Reverts() public {
        _deposit(address(0x1111), 1000e6);
        vm.prank(agent);
        vault.parkUsdc(address(usdcA), 400e6);
        uint256 sh = vr.sharesOf(address(usdcA));
        _stress(usdcA, 9500, false, 10_000); // STRESS

        MockERC4626Vault rogue = new MockERC4626Vault(IERC20(address(usdc)), "Rogue", "RG");
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(VaultRouter.NotWhitelisted.selector, address(rogue)));
        vault.fleeToBackup(address(usdcA), address(rogue), sh);
        // funds untouched (whole tx reverted)
        assertEq(vr.sharesOf(address(usdcA)), sh);
    }

    function test_Agent_CannotEmergency_WithoutSignal_OwnerCan() public {
        _deposit(address(0x1111), 1000e6);
        vm.prank(agent);
        vault.parkUsdc(address(usdcA), 400e6);

        // usdcA healthy → agent emergency call rejected
        vm.prank(agent);
        vm.expectRevert(AllocatorVault.NoEmergency.selector);
        vault.emergencyExitAll(address(usdcA));

        // owner (guardian) may force an exit at any time
        vault.emergencyExitAll(address(usdcA)); // msg.sender = owner (this test contract)
        assertEq(vr.sharesOf(address(usdcA)), 0);
    }

    // ----- full 3-tier stress trace for the report -----
    function test_Trace_ThreeTierStress() public {
        _deposit(address(0x1111), 1000e6);
        console2.log("=== P4c 3-TIER STRESS TRACE ===");

        vm.prank(agent);
        vault.parkUsdc(address(usdcA), 300e6);
        vm.prank(agent);
        vault.parkUsdc(address(usdcB), 200e6);
        _logTiers("[HEALTHY] parked 300 in A, 200 in B");

        // --- CAUTION: A utilization elevated → stop adding to A ---
        _stress(usdcA, 7500, false, 10_000);
        _logTiers("[CAUTION] A utilization 7500bps");
        vm.prank(agent);
        try vault.parkUsdc(address(usdcA), 50e6) { console2.log("  add to A: ALLOWED (unexpected)"); }
        catch { console2.log("  add to A: BLOCKED (StopAdding) -- correct"); }

        // --- STRESS: A withdraw-at-risk → flee A into backup B ---
        _stress(usdcA, 9500, false, 10_000);
        _logTiers("[STRESS] A utilization 9500bps -> flee A to B");
        uint256 shA = vr.sharesOf(address(usdcA));
        vm.prank(agent);
        vault.fleeToBackup(address(usdcA), address(usdcB), shA);
        console2.log("  after flee -> A shares:", vr.sharesOf(address(usdcA)), " B shares:", vr.sharesOf(address(usdcB)));

        // --- EMERGENCY: B paused → pull ALL parked to base ---
        _stress(usdcB, 0, true, 10_000);
        _logTiers("[EMERGENCY] B paused -> pull all to base");
        vm.prank(agent);
        vault.emergencyExitAll(address(usdcB));
        (, uint256 parked) = vault.legBreakdown();
        console2.log("  after emergency -> parked value (6d):", parked, " base USDC (6d):", vault.trackedUsdc());
        console2.log("  NAV (6d):", vault.totalAssets(), " logbook entries:", logbook.count());
    }

    function _logTiers(string memory tag) internal view {
        console2.log(tag);
        console2.log("  tier A / B:", _tierName(monitor.tierOf(address(usdcA))), _tierName(monitor.tierOf(address(usdcB))));
    }

    function _tierName(HealthMonitor.Tier t) internal pure returns (string memory) {
        if (t == HealthMonitor.Tier.HEALTHY) return "HEALTHY";
        if (t == HealthMonitor.Tier.CAUTION) return "CAUTION";
        if (t == HealthMonitor.Tier.STRESS) return "STRESS";
        return "EMERGENCY";
    }
}

// ----------------- invariant suite (stress sequences) -----------------

contract SafetyHandler is SafetyFixture {
    function setUpHandler() external { _deploySafety(); _seedDeadShares(1e6); }

    function deposit(uint256 amt) public {
        amt = bound(amt, 1e6, 1e14);
        address a = address(0xB1);
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(vault), amt);
        try vault.deposit(amt, a) {} catch {}
        vm.stopPrank();
    }

    function parkUsdc(uint256 amt, uint256 which) public {
        uint256 tu = vault.trackedUsdc();
        if (tu < 2e6) return;
        amt = bound(amt, 1e6, tu);
        address v = which % 2 == 0 ? address(usdcA) : address(usdcB);
        vm.prank(agent);
        try vault.parkUsdc(v, amt) {} catch {}
    }

    function setStressA(uint256 util, uint256 pegSeed, uint256 pauseSeed) public {
        util = bound(util, 0, 10_000);
        uint256 peg = bound(pegSeed, 8000, 10_000);
        usdcA.setStress(util, pauseSeed % 5 == 0, peg);
    }

    function slashA(uint256 amt) public {
        uint256 held = usdc.balanceOf(address(usdcA));
        if (held == 0) return;
        amt = bound(amt, 0, held / 4);
        try usdcA.slashValue(amt) {} catch {}
    }

    function flee(uint256) public {
        uint256 sh = vr.sharesOf(address(usdcA));
        if (sh == 0) return;
        vm.prank(agent);
        try vault.fleeToBackup(address(usdcA), address(usdcB), sh) {} catch {}
    }

    function emergency(uint256) public {
        vm.prank(agent);
        try vault.emergencyExitAll(address(usdcA)) {} catch {}
        // owner-forced path too
        try vault.emergencyExitAll(address(usdcB)) {} catch {}
    }

    function redeem(uint256 sharesSeed) public {
        uint256 bal = vault.balanceOf(address(0xB1));
        if (bal == 0) return;
        uint256 sh = bound(sharesSeed, 1, bal);
        vm.prank(address(0xB1));
        try vault.redeemInKind(sh, address(0xB1)) {} catch {}
    }
}

contract AllocatorVaultSafetyInvariants is Test {
    SafetyHandler handler;
    AllocatorVault vault;
    VaultRouter vr;

    function setUp() public {
        handler = new SafetyHandler();
        handler.setUpHandler();
        vault = handler.vault();
        vr = handler.vr();

        bytes4[] memory sel = new bytes4[](7);
        sel[0] = handler.deposit.selector;
        sel[1] = handler.parkUsdc.selector;
        sel[2] = handler.setStressA.selector;
        sel[3] = handler.slashA.selector;
        sel[4] = handler.flee.selector;
        sel[5] = handler.emergency.selector;
        sel[6] = handler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    // INV: user-withdrawable (NAV) never exceeds the assets actually backing it —
    // base solvency holds under ANY stress sequence.
    function invariant_BaseSolvency() public view {
        assertGe(handler.usdc().balanceOf(address(vault)), vault.trackedUsdc());
        assertGe(address(vault).balance, vault.trackedMon());
    }

    // INV: funds only ever sit in WHITELISTED destinations (ERC4626 shares of
    // owner-approved venues, held by the router) or in BASE assets (the vault).
    // The router never holds loose USDC/WMON between actions → nothing is in transit
    // to, or stuck at, a non-whitelisted address.
    function invariant_FundsOnlyInWhitelistedOrBase() public view {
        assertEq(handler.usdc().balanceOf(address(vr)), 0);
        assertEq(handler.wmon().balanceOf(address(vr)), 0);
    }

    // INV: NAV sums all legs exactly once at all times.
    function invariant_NavSumsAllLegsOnce() public view {
        (uint256 bu, uint256 bm, uint256 legs, uint256 total) = vault.navBreakdown();
        assertEq(bu + bm + legs, total);
        assertEq(total, vault.totalAssets());
    }
}
