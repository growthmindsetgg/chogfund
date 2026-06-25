// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {AllocatorVault, IWMON} from "../src/AllocatorVault.sol";
import {HardenedVault, ILogBook} from "../src/HardenedVault.sol";
import {LpManager} from "../src/LpManager.sol";
import {PythPriceReader} from "../src/PythPriceReader.sol";
import {MockWMON} from "../src/MockWMON.sol";
import {MockUniV3Pool} from "../src/MockUniV3Pool.sol";
import {MockUniV3PositionManager} from "../src/MockUniV3PositionManager.sol";
import {INonfungiblePositionManager} from "../src/external/uniswap/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "../src/external/uniswap/IUniswapV3Pool.sol";
import {TickMath} from "../src/external/uniswap/TickMath.sol";
import {FullMath} from "../src/external/uniswap/FullMath.sol";
import {IPyth, PythStructs} from "../src/interfaces/IPyth.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ----------------- test doubles (shared with P3 patterns) -----------------

contract TUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract MockPyth is IPyth {
    mapping(bytes32 => PythStructs.Price) internal _p;
    function set(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 pt) external {
        _p[id] = PythStructs.Price(price, conf, expo, pt);
    }
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythStructs.Price memory) {
        PythStructs.Price memory p = _p[id];
        require(p.publishTime != 0, "PriceFeedNotFound");
        require(block.timestamp - p.publishTime <= age, "StalePrice");
        return p;
    }
    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) { return _p[id]; }
    function getUpdateFee(bytes[] calldata) external pure returns (uint256) { return 1; }
    function updatePriceFeeds(bytes[] calldata) external payable {}
}

contract MockLogBook is ILogBook {
    uint256 public count;
    function record(uint256, uint256, uint256, uint256, uint256) external { count++; }
}

// P3-style router: swaps USDC <-> native MON at the price encoded in calldata.
contract MockSwapRouter {
    address constant NATIVE = address(0);
    function swap(address tokenIn, address tokenOut, uint256 pullIn, uint256 pushOut) external payable {
        if (tokenIn != NATIVE && pullIn > 0) IERC20(tokenIn).transferFrom(msg.sender, address(this), pullIn);
        if (pushOut > 0) {
            if (tokenOut == NATIVE) { (bool ok,) = msg.sender.call{value: pushOut}(""); require(ok, "nat"); }
            else require(IERC20(tokenOut).transfer(msg.sender, pushOut), "erc");
        }
    }
    receive() external payable {}
}

// ----------------- fixture -----------------

contract LpFixture is Test {
    TUSDC public usdc;
    MockWMON public wmon;
    MockPyth public pyth;
    PythPriceReader public reader;
    MockLogBook public logbook;
    MockSwapRouter public router;
    MockUniV3Pool public pool;
    MockUniV3PositionManager public npm;
    LpManager public lp;
    AllocatorVault public vault;

    bytes32 constant FEED = 0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address agent = address(0xA9E37);
    uint256 constant NOW = 1_782_000_000;
    uint256 constant Q96 = 0x1000000000000000000000000;

    int24 constant SPACING = 60;
    int24 constant RANGE = 6000;   // ±100 spacings → ±~80% band
    bool usdcIsToken0;
    int24 centerTick;              // ~$2 / MON, ordering-aware

    function _deploy() internal {
        vm.warp(NOW);
        usdc = new TUSDC();
        wmon = new MockWMON();
        pyth = new MockPyth();
        reader = new PythPriceReader(IPyth(address(pyth)), FEED, 3600, 100);
        logbook = new MockLogBook();
        router = new MockSwapRouter();

        // token ordering decides token0/token1 + the sign of the $2 tick
        usdcIsToken0 = address(usdc) < address(wmon);
        (address t0, address t1) = usdcIsToken0 ? (address(usdc), address(wmon)) : (address(wmon), address(usdc));
        // ~$2/MON: WMON=token0 -> negative tick; USDC=token0 -> positive (inverse)
        centerTick = usdcIsToken0 ? int24(269400) : int24(-269400);

        uint160 startSqrt = TickMath.getSqrtRatioAtTick(centerTick);
        pool = new MockUniV3Pool(t0, t1, 3000, SPACING, startSqrt);
        npm = new MockUniV3PositionManager(pool);
        lp = new LpManager(INonfungiblePositionManager(address(npm)), IUniswapV3Pool(address(pool)), reader, address(wmon), address(usdc));

        vault = new AllocatorVault(IERC20(address(usdc)), reader, ILogBook(address(logbook)), agent, 50, IWMON(address(wmon)));
        vault.setLpManager(lp);
        lp.setVault(address(vault));
        vault.setRouterWhitelist(address(router), true);

        // deep liquidity for P3 rebalance swaps (USDC<->native MON)
        usdc.mint(address(router), 1e24);
        vm.deal(address(router), 1e30);

        // buffer the MOCK position manager so one-sided (out-of-range) withdrawals are
        // payable — mirrors a real pool's aggregate reserves backing a single position.
        _fundWmon(address(npm), 1e24);
        usdc.mint(address(npm), 1e24);

        _syncPyth();
    }

    // ----- market control: set pool tick AND the implied Pyth price together -----

    function _setMarketTick(int24 tick) internal {
        pool.setTick(tick);
        _syncPyth();
    }

    /// @dev Derive the $/MON priceE8 implied by the pool's sqrtPrice + decimals/ordering,
    ///      and publish it to Pyth so the trustless price tracks the (mock) market.
    function _impliedPriceE8() internal view returns (uint256) {
        (uint160 s,,,,,,) = pool.slot0();
        uint256 q = FullMath.mulDiv(uint256(s), uint256(s), Q96); // P_pool * Q96  (token1/token0, raw)
        if (!usdcIsToken0) {
            // WMON=token0: $/MON = P_pool * 1e12 ; priceE8 = P_pool * 1e20
            return FullMath.mulDiv(q, 1e20, Q96);
        } else {
            // USDC=token0: priceE8 = 1e20 / P_pool
            return FullMath.mulDiv(1e20, Q96, q);
        }
    }

    function _syncPyth() internal {
        uint256 e8 = _impliedPriceE8();
        pyth.set(FEED, int64(uint64(e8)), uint64(e8 / 200 + 1), int32(-8), block.timestamp);
    }

    // ----- helpers -----

    function _fundWmon(address to, uint256 amt) internal {
        vm.deal(address(this), amt);
        wmon.deposit{value: amt}();
        wmon.transfer(to, amt);
    }

    function _seedDeadShares(uint256 amt) internal {
        usdc.mint(address(0xF00D), amt);
        vm.startPrank(address(0xF00D));
        usdc.approve(address(vault), amt);
        vault.deposit(amt, DEAD);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev Build a base MON position by running a P3 rebalance (USDC -> native MON).
    function _rebalanceIntoMon(uint256 usdcIn) internal {
        uint256 p = reader.readPriceE8();
        uint256 grossMon = usdcIn * 1e20 / p;
        bytes memory cd = abi.encodeWithSelector(MockSwapRouter.swap.selector, address(usdc), address(0), usdcIn, grossMon);
        vm.prank(agent);
        vault.rebalance(address(router), cd, false, usdcIn);
    }

    function _allocate(uint256 monAmt, uint256 usdcAmt) internal {
        vm.prank(agent);
        vault.allocateToLp(monAmt, usdcAmt, centerTick - RANGE, centerTick + RANGE);
    }
}

// ----------------- unit tests -----------------

contract AllocatorVaultLpTest is LpFixture {
    uint256 navBeforeAlloc;

    function setUp() public { _deploy(); _seedDeadShares(1e6); }

    function _primeBaseAndAllocate() internal returns (uint256 monAlloc, uint256 usdcAlloc) {
        _deposit(address(0x1111), 1000e6);          // 100% USDC
        _rebalanceIntoMon(500e6);                    // ~half into native MON
        monAlloc = vault.trackedMon() / 2;
        usdcAlloc = vault.trackedUsdc() / 2;
        navBeforeAlloc = vault.totalAssets();        // NAV just before the allocation
        _allocate(monAlloc, usdcAlloc);
    }

    function test_OpenAtTargetTicks_FromPrice() public {
        _primeBaseAndAllocate();
        uint256 navBefore = navBeforeAlloc;

        assertTrue(lp.tokenId() != 0, "no position opened");
        assertEq(lp.tickLower(), centerTick - RANGE);
        assertEq(lp.tickUpper(), centerTick + RANGE);

        (,,, uint256 total) = vault.navBreakdown();
        (,, uint256 lpValue,) = vault.navBreakdown();
        assertGt(lpValue, 0, "LP leg not valued");
        // NAV breakdown sums to totalAssets (leg counted exactly once)
        assertEq(total, vault.totalAssets(), "breakdown != totalAssets");
        // allocation conserved NAV within the slippage cap
        assertApproxEqRel(vault.totalAssets(), navBefore, 1e16); // within 1%
    }

    function test_InRange_FeesAccrue_Collect_NAV() public {
        _primeBaseAndAllocate();
        uint256 navMid = vault.totalAssets();

        // simulate trading fees accruing to the position (MOCK control surface)
        (, , , , , , uint128 owed0Before, uint128 owed1Before,) = npm.pos(lp.tokenId());
        owed0Before; owed1Before;
        // fee amounts: token0 + token1. Map to a few USDC + a little WMON regardless of order.
        (uint128 fee0, uint128 fee1) = usdcIsToken0 ? (uint128(10e6), uint128(1e18)) : (uint128(1e18), uint128(10e6));
        npm.accrueFees(lp.tokenId(), fee0, fee1);

        uint256 navWithFees = vault.totalAssets();
        assertGt(navWithFees, navMid, "fees did not raise NAV");

        // harvest fees into base; NAV essentially unchanged, base balances rise
        uint256 tuBefore = vault.trackedUsdc();
        uint256 tmBefore = vault.trackedMon();
        vm.prank(agent);
        vault.collectLpFees();
        assertGt(vault.trackedUsdc(), tuBefore, "usdc fees not banked");
        assertGt(vault.trackedMon(), tmBefore, "mon fees not banked");
        assertApproxEqRel(vault.totalAssets(), navWithFees, 1e15); // within 0.1%
    }

    function test_OutOfRange_OneSided_NAV() public {
        _primeBaseAndAllocate();
        uint256 navInRange = vault.totalAssets();

        // push price far above the upper tick -> position becomes one-sided
        _setMarketTick(centerTick + RANGE + 4000);

        (, uint256 wmonAmt, uint256 usdcAmt,,) = lp.positionAmounts();
        // exactly one side should be ~zero (concentrated), the other holds the value
        assertTrue(wmonAmt == 0 || usdcAmt == 0, "not one-sided out of range");

        // NAV still computable and the breakdown still sums exactly once
        (,,, uint256 total) = vault.navBreakdown();
        assertEq(total, vault.totalAssets(), "breakdown != totalAssets out of range");
        // value moved (price changed) but remains a sane positive number
        assertGt(vault.totalAssets(), 0);
        navInRange;
    }

    function test_ShiftRange_NoValueLost() public {
        _primeBaseAndAllocate();
        // drift the price up within the band, then re-center the range there
        _setMarketTick(centerTick + 3000);
        uint256 navBefore = vault.totalAssets();
        uint256 oldId = lp.tokenId();

        vm.prank(agent);
        vault.shiftLpRange(centerTick + 3000 - RANGE, centerTick + 3000 + RANGE);

        assertTrue(lp.tokenId() != 0 && lp.tokenId() != oldId, "range not re-opened");
        assertEq(lp.tickLower(), centerTick + 3000 - RANGE);
        // value conserved beyond modeled cost (mock cost ~0)
        assertApproxEqRel(vault.totalAssets(), navBefore, 1e15); // within 0.1%
    }

    function test_Withdraw_UnwindsLpProRata() public {
        uint256 s = _deposit(address(0x1111), 1000e6);
        _rebalanceIntoMon(500e6);
        _allocate(vault.trackedMon() / 2, vault.trackedUsdc() / 2);

        uint256 navPerShareBefore = vault.convertToAssets(1e12);
        uint256 userUsdcBefore = usdc.balanceOf(address(0x1111));
        uint256 userMonBefore = address(0x1111).balance;

        vm.prank(address(0x1111));
        (uint256 usdcOut, uint256 monOut) = vault.redeemInKind(s, address(0x1111));

        // user received BOTH base and unwound-LP proceeds
        assertGt(usdcOut, 0, "no usdc out");
        assertGt(monOut, 0, "no mon out");
        assertEq(usdc.balanceOf(address(0x1111)) - userUsdcBefore, usdcOut);
        assertEq(address(0x1111).balance - userMonBefore, monOut);
        // share price did not drop for the (dead-share) remainder
        assertGe(vault.convertToAssets(1e12), navPerShareBefore - 2);
    }

    // ----- range-shift trace (for the P4a report) -----

    function _logBreakdown(string memory tag) internal view {
        (uint256 bu, uint256 bm, uint256 lpv, uint256 tot) = vault.navBreakdown();
        console2.log(tag);
        console2.log("  priceE8 ($/MON, 8dec):", reader.readPriceE8());
        console2.log("  pool tick / lp range lo / hi:", vm.toString(_tick()), vm.toString(lp.tickLower()), vm.toString(lp.tickUpper()));
        console2.log("  base USDC (6d):", bu);
        console2.log("  base MON value (6d):", bm);
        console2.log("  LP leg value (6d):", lpv);
        console2.log("  NAV total (6d):", tot);
    }

    function _tick() internal view returns (int24 t) { (, t,,,,,) = pool.slot0(); }

    function test_Trace_RangeShift() public {
        _deposit(address(0x1111), 1000e6);
        _rebalanceIntoMon(500e6);
        _allocate(vault.trackedMon() * 80 / 100, vault.trackedUsdc() * 80 / 100);
        console2.log("=== P4a RANGE-SHIFT TRACE ===");
        _logBreakdown("[1] after allocate (in range)");

        // accrue some fees, then the market drifts up toward the upper tick
        (uint128 f0, uint128 f1) = usdcIsToken0 ? (uint128(3e6), uint128(5e17)) : (uint128(5e17), uint128(3e6));
        npm.accrueFees(lp.tokenId(), f0, f1);
        _setMarketTick(centerTick + 4500);
        _logBreakdown("[2] +fees, price drifted up 4500 ticks");

        // agent re-centers the range on the new price
        uint256 navPre = vault.totalAssets();
        vm.prank(agent);
        vault.shiftLpRange(centerTick + 4500 - RANGE, centerTick + 4500 + RANGE);
        _logBreakdown("[3] after shiftLpRange (re-centered)");
        console2.log("  NAV conserved? before/after (6d):", navPre, vault.totalAssets());
        console2.log("  logbook entries:", logbook.count());
    }

    // ----- non-custodial / access control -----

    function test_Agent_CannotTouchLpManagerDirectly() public {
        _primeBaseAndAllocate();
        vm.startPrank(agent);
        vm.expectRevert(LpManager.NotVault.selector);
        lp.unwind(1, 2);
        vm.expectRevert(LpManager.NotVault.selector);
        lp.collectFees();
        vm.stopPrank();
    }

    function test_Agent_CannotSetLpManager() public {
        vm.prank(agent);
        vm.expectRevert(HardenedVault.NotOwner.selector);
        vault.setLpManager(lp);
    }

    function test_Allocate_CannotExceedTracked() public {
        _deposit(address(0x1111), 1000e6);
        uint256 over = vault.trackedUsdc() + 1; // evaluate BEFORE expectRevert
        vm.prank(agent);
        vm.expectRevert(HardenedVault.AmountExceedsTracked.selector);
        vault.allocateToLp(0, over, centerTick - RANGE, centerTick + RANGE);
    }

    // ----- fuzz: allocate arbitrary split, fully redeem, check no value leak -----
    function testFuzz_AllocThenRedeem_NoLeak(uint96 depositAmt, uint16 monPct, uint16 usdcPct) public {
        depositAmt = uint96(bound(depositAmt, 10e6, 1e15));
        monPct = uint16(bound(monPct, 1, 90));
        usdcPct = uint16(bound(usdcPct, 1, 90));

        uint256 s = _deposit(address(0x2222), depositAmt);
        _rebalanceIntoMon(depositAmt / 2);

        uint256 monAmt = vault.trackedMon() * monPct / 100;
        uint256 usdcAmt = vault.trackedUsdc() * usdcPct / 100;
        uint256 navBefore = vault.totalAssets();
        _allocate(monAmt, usdcAmt);
        // allocation conserved NAV within slippage
        assertApproxEqRel(vault.totalAssets(), navBefore, 2e16);

        uint256 valueBefore = vault.convertToAssets(s);
        vm.prank(address(0x2222));
        (uint256 usdcOut, uint256 monOut) = vault.redeemInKind(s, address(0x2222));
        // redeemed value (USDC + MON@price) ~ the share's NAV value, no leak
        uint256 p = reader.readPriceE8();
        uint256 redeemedValue = usdcOut + monOut * p / 1e20;
        assertApproxEqRel(redeemedValue, valueBefore, 2e16); // within 2%
    }
}

// ----------------- invariant suite -----------------

contract LpHandler is LpFixture {
    uint256 public ghostDeposited;

    function setUpHandler() external { _deploy(); _seedDeadShares(1e6); }

    function deposit(uint256 amt) public {
        amt = bound(amt, 1e6, 1e14);
        address a = address(0xB1);
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(vault), amt);
        try vault.deposit(amt, a) { ghostDeposited += amt; } catch {}
        vm.stopPrank();
    }

    function rebalanceToMon(uint256 amt) public {
        uint256 tu = vault.trackedUsdc();
        if (tu < 2e6) return;
        amt = bound(amt, 1e6, tu / 2);
        try this.extRebalance(amt) {} catch {}
    }
    function extRebalance(uint256 amt) external { _rebalanceIntoMon(amt); }

    function allocate(uint256 monAmt, uint256 usdcAmt) public {
        uint256 tm = vault.trackedMon();
        uint256 tu = vault.trackedUsdc();
        if (tm < 1e15 || tu < 2e6) return;
        monAmt = bound(monAmt, 1e14, tm);
        usdcAmt = bound(usdcAmt, 1e6, tu);
        try this.extAllocate(monAmt, usdcAmt) {} catch {}
    }
    function extAllocate(uint256 m, uint256 u) external { _allocate(m, u); }

    function moveMarket(uint256 seed) public {
        int24 delta = int24(int256(bound(seed, 0, 8000)) - 4000);
        try this.extMove(centerTick + delta) {} catch {}
    }
    function extMove(int24 t) external { _setMarketTick(t); }

    function accrue(uint256 f) public {
        if (lp.tokenId() == 0) return;
        f = bound(f, 0, 1e9);
        (uint128 a, uint128 b) = usdcIsToken0 ? (uint128(f), uint128(f * 1e10)) : (uint128(f * 1e10), uint128(f));
        try npm.accrueFees(lp.tokenId(), a, b) {} catch {}
    }

    function redeem(uint256 sharesSeed) public {
        uint256 bal = vault.balanceOf(address(0xB1));
        if (bal == 0) return;
        uint256 sh = bound(sharesSeed, 1, bal);
        vm.prank(address(0xB1));
        try vault.redeemInKind(sh, address(0xB1)) {} catch {}
    }

    receive() external payable {}
}

contract AllocatorVaultLpInvariants is Test {
    LpHandler handler;
    AllocatorVault vault;
    TUSDC usdc;
    MockWMON wmon;
    LpManager lp;

    function setUp() public {
        handler = new LpHandler();
        handler.setUpHandler();
        vault = handler.vault();
        usdc = handler.usdc();
        wmon = handler.wmon();
        lp = handler.lp();

        bytes4[] memory sel = new bytes4[](6);
        sel[0] = handler.deposit.selector;
        sel[1] = handler.rebalanceToMon.selector;
        sel[2] = handler.allocate.selector;
        sel[3] = handler.moveMarket.selector;
        sel[4] = handler.accrue.selector;
        sel[5] = handler.redeem.selector;
        FuzzSelector memory fs = FuzzSelector({addr: address(handler), selectors: sel});
        targetSelector(fs);
        targetContract(address(handler));
    }

    // INV: base solvency — the vault physically holds at least its tracked base assets.
    // (LP value lives in the position; base claims must always be payable.)
    function invariant_BaseSolvency() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.trackedUsdc());
        assertGe(address(vault).balance, vault.trackedMon());
    }

    // INV: the NAV breakdown sums each leg exactly once and equals totalAssets().
    function invariant_NavSumsLegsOnce() public view {
        (uint256 baseUsdc, uint256 baseMonValue, uint256 lpValue, uint256 total) = vault.navBreakdown();
        assertEq(baseUsdc + baseMonValue + lpValue, total);
        assertEq(total, vault.totalAssets());
    }

    // INV: shares are always backed by some asset (base or LP).
    function invariant_NoUnbackedShares() public view {
        if (vault.totalSupply() > 0) {
            assertGt(vault.totalAssets(), 0);
        }
    }
}
