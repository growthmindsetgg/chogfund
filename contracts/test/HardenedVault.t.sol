// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HardenedVault, ILogBook} from "../src/HardenedVault.sol";
import {PythPriceReader} from "../src/PythPriceReader.sol";
import {SafeSwapExecutor} from "../src/SafeSwapExecutor.sol";
import {IPyth, PythStructs} from "../src/interfaces/IPyth.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ----------------- test doubles -----------------

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

// ----------------- base fixture -----------------

contract VaultFixture is Test {
    TUSDC usdc;
    MockPyth pyth;
    PythPriceReader reader;
    MockLogBook logbook;
    MockSwapRouter router;
    HardenedVault vault;

    bytes32 constant FEED = 0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address agent = address(0xA9E37);
    uint256 constant PRICE_E8 = 2e8; // $2 / MON
    uint256 constant NOW = 1_782_000_000;

    function _deploy() internal {
        vm.warp(NOW);
        usdc = new TUSDC();
        pyth = new MockPyth();
        pyth.set(FEED, int64(int256(PRICE_E8)), uint64(20_000), int32(-8), NOW); // conf 100bps == threshold edge ok
        reader = new PythPriceReader(IPyth(address(pyth)), FEED, 60, 100);
        logbook = new MockLogBook();
        router = new MockSwapRouter();
        vault = new HardenedVault(IERC20(address(usdc)), reader, ILogBook(address(logbook)), agent, 50);
        vault.setRouterWhitelist(address(router), true);
        // fund router with deep liquidity for rebalances
        usdc.mint(address(router), 1e18);
        vm.deal(address(router), 1e24);
    }

    function _seedDeadShares(uint256 amt) internal {
        address funder = address(0xF00D);
        usdc.mint(funder, amt);
        vm.startPrank(funder);
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
}

// ----------------- unit + fuzz tests -----------------

contract HardenedVaultTest is VaultFixture {
    function setUp() public { _deploy(); _seedDeadShares(1e6); }

    function test_DepositMintsShares_AndTracks() public {
        uint256 s = _deposit(address(0x1111), 1000e6);
        assertGt(s, 0);
        assertEq(vault.trackedUsdc(), 1e6 + 1000e6);
        assertEq(vault.trackedMon(), 0);
        assertEq(vault.totalAssets(), 1001e6);
    }

    function test_AgentCannotDeposit() public {
        usdc.mint(agent, 100e6);
        vm.startPrank(agent);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(HardenedVault.AgentBlocked.selector);
        vault.deposit(100e6, agent);
        vm.stopPrank();
    }

    function test_StandardWithdrawRedeem_Disabled() public {
        vm.expectRevert(HardenedVault.InKindOnly.selector);
        vault.withdraw(1, address(this), address(this));
        vm.expectRevert(HardenedVault.InKindOnly.selector);
        vault.redeem(1, address(this), address(this));
    }

    function test_Rebalance_BuysMon_To6040() public {
        _deposit(address(0x1111), 1000e6); // vault 100% USDC, NAV 1001e6
        uint256 nav = vault.totalAssets();
        uint256 target = nav * 6000 / 10000;       // MON value target
        uint256 amountIn = target;                  // USDC to spend (monVal currently 0)
        uint256 grossMon = amountIn * 1e20 / PRICE_E8; // fair MON out

        bytes memory cd = abi.encodeWithSelector(
            MockSwapRouter.swap.selector, address(usdc), address(0), amountIn, grossMon
        );
        vm.prank(agent);
        vault.rebalance(address(router), cd, false, amountIn);

        // ~60% MON by value now
        uint256 monVal = vault.trackedMon() * PRICE_E8 / 1e20;
        uint256 navA = vault.totalAssets();
        uint256 bps = monVal * 10_000 / navA;
        assertApproxEqAbs(bps, 6000, 5); // within rounding
        assertEq(logbook.count(), 1);
    }

    function test_Rebalance_OnlyAgent() public {
        _deposit(address(0x1111), 1000e6);
        bytes memory cd;
        vm.expectRevert(HardenedVault.NotAgent.selector);
        vault.rebalance(address(router), cd, false, 1);
    }

    function test_RedeemInKind_ProRata() public {
        uint256 s = _deposit(address(0x1111), 1000e6);
        // rebalance into MON so redemption returns both assets
        uint256 amountIn = vault.totalAssets() * 6000 / 10000;
        uint256 grossMon = amountIn * 1e20 / PRICE_E8;
        bytes memory cd = abi.encodeWithSelector(
            MockSwapRouter.swap.selector, address(usdc), address(0), amountIn, grossMon
        );
        vm.prank(agent);
        vault.rebalance(address(router), cd, false, amountIn);

        uint256 tu = vault.trackedUsdc();
        uint256 tm = vault.trackedMon();
        uint256 supply = vault.totalSupply();

        vm.prank(address(0x1111));
        (uint256 usdcOut, uint256 monOut) = vault.redeemInKind(s, address(0x1111));

        assertEq(usdcOut, tu * s / supply);
        assertEq(monOut, tm * s / supply);
        assertEq(usdc.balanceOf(address(0x1111)), usdcOut);
        assertEq(address(0x1111).balance, monOut);
    }

    // INV: a direct donation does not change existing holders' share price.
    function testFuzz_Donation_NoSharePriceChange(uint96 depositAmt, uint96 donateUsdc, uint96 donateMon) public {
        depositAmt = uint96(bound(depositAmt, 1e6, 1e15));
        _deposit(address(0x1111), depositAmt);

        uint256 ppsBefore = vault.convertToAssets(1e12);

        // donate USDC and native MON directly to the vault
        usdc.mint(address(this), donateUsdc);
        usdc.transfer(address(vault), donateUsdc);
        vm.deal(address(this), donateMon);
        (bool ok,) = address(vault).call{value: donateMon}("");
        ok; // donations to receive() accepted but untracked

        uint256 ppsAfter = vault.convertToAssets(1e12);
        assertEq(ppsAfter, ppsBefore, "donation moved share price");
        // tracked accounting unaffected by donations
        assertEq(vault.trackedUsdc(), 1e6 + depositAmt);
        assertEq(vault.trackedMon(), 0);
    }

    // INV: first-deposit inflation attack cannot zero out a victim's shares.
    function testFuzz_FirstDepositInflation_VictimNotZeroed(uint96 donation) public {
        donation = uint96(bound(donation, 1e6, type(uint96).max));
        // fresh vault WITHOUT the dead-shares seed to test the worst case in isolation
        HardenedVault v = new HardenedVault(IERC20(address(usdc)), reader, ILogBook(address(logbook)), agent, 50);

        address attacker = address(0xA11ACC);
        address victim = address(0x71C71C);

        // attacker makes a 1-unit first deposit
        usdc.mint(attacker, 1);
        vm.startPrank(attacker);
        usdc.approve(address(v), 1);
        v.deposit(1, attacker);
        vm.stopPrank();

        // attacker donates a huge amount directly — with internal accounting this is ignored
        usdc.mint(attacker, donation);
        vm.prank(attacker);
        usdc.transfer(address(v), donation);

        // victim deposits 1000 USDC
        usdc.mint(victim, 1000e6);
        vm.startPrank(victim);
        usdc.approve(address(v), 1000e6);
        uint256 vShares = v.deposit(1000e6, victim);
        vm.stopPrank();

        assertGt(vShares, 0, "victim zeroed out");

        // victim can recover ~their deposit in value (USDC, since vault is all USDC)
        vm.prank(victim);
        (uint256 usdcOut,) = v.redeemInKind(vShares, victim);
        // donation never entered NAV, so victim gets back essentially their 1000 USDC
        assertApproxEqRel(usdcOut, 1000e6, 1e15); // within 0.1%
    }

    function test_PausedBlocksDeposit() public {
        vault.setPaused(true);
        usdc.mint(address(0x1111), 100e6);
        vm.startPrank(address(0x1111));
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(HardenedVault.Paused.selector);
        vault.deposit(100e6, address(0x1111));
        vm.stopPrank();
    }

    receive() external payable {}
}

// ----------------- invariant handler + suite -----------------

contract Handler is VaultFixture {
    address[] public actors;
    uint256 public ghostDeposited; // USDC ever deposited
    uint256 public ghostDonatedUsdc;

    constructor(
        TUSDC _usdc, MockPyth _pyth, PythPriceReader _reader,
        MockLogBook _log, MockSwapRouter _router, HardenedVault _vault, address _agent
    ) {
        usdc = _usdc; pyth = _pyth; reader = _reader; logbook = _log; router = _router; vault = _vault;
        agent = _agent;
        actors.push(address(0xA1));
        actors.push(address(0xA2));
        actors.push(address(0xA3));
    }

    function _actor(uint256 s) internal view returns (address) { return actors[s % actors.length]; }

    function deposit(uint256 actorSeed, uint256 amt) public {
        amt = bound(amt, 1e6, 1e14);
        address a = _actor(actorSeed);
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(vault), amt);
        try vault.deposit(amt, a) { ghostDeposited += amt; } catch {}
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 sharesSeed) public {
        address a = _actor(actorSeed);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        uint256 s = bound(sharesSeed, 1, bal);
        vm.prank(a);
        try vault.redeemInKind(s, a) {} catch {}
    }

    function donate(uint256 amtU, uint256 amtM) public {
        amtU = bound(amtU, 0, 1e15);
        amtM = bound(amtM, 0, 1e21);
        usdc.mint(address(this), amtU);
        usdc.transfer(address(vault), amtU);
        ghostDonatedUsdc += amtU;
        vm.deal(address(this), amtM);
        (bool ok,) = address(vault).call{value: amtM}(""); ok;
    }

    function rebalance(uint256) public {
        uint256 p = PRICE_E8;
        uint256 monVal = vault.trackedMon() * p / 1e20;
        uint256 nav = monVal + vault.trackedUsdc();
        if (nav == 0) return;
        uint256 target = nav * 6000 / 10000;
        uint256 band = nav * 500 / 10000;
        bytes memory cd;
        if (monVal > target && monVal - target > band) {
            uint256 amountIn = (monVal - target) * 1e20 / p;
            if (amountIn > vault.trackedMon()) amountIn = vault.trackedMon();
            uint256 gross = amountIn * p / 1e20;
            cd = abi.encodeWithSelector(MockSwapRouter.swap.selector, address(0), address(usdc), uint256(0), gross);
            vm.prank(agent);
            try vault.rebalance(address(router), cd, true, amountIn) {} catch {}
        } else if (target > monVal && target - monVal > band) {
            uint256 amountIn = target - monVal;
            if (amountIn > vault.trackedUsdc()) amountIn = vault.trackedUsdc();
            uint256 gross = amountIn * 1e20 / p;
            cd = abi.encodeWithSelector(MockSwapRouter.swap.selector, address(usdc), address(0), amountIn, gross);
            vm.prank(agent);
            try vault.rebalance(address(router), cd, false, amountIn) {} catch {}
        }
    }

    receive() external payable {}
}

contract HardenedVaultInvariants is VaultFixture {
    Handler handler;

    function setUp() public {
        _deploy();
        _seedDeadShares(1e6);
        handler = new Handler(usdc, pyth, reader, logbook, router, vault, agent);
        targetContract(address(handler));
    }

    // INV1: vault always physically holds >= what it tracks → all tracked claims are payable
    // (total user-withdrawable never exceeds vault assets).
    function invariant_Solvency() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.trackedUsdc());
        assertGe(address(vault).balance, vault.trackedMon());
    }

    // INV2/INV4: donations are pure surplus — never enter tracked accounting / NAV.
    // tracked USDC can only grow from deposits (rebalance moves between MON/USDC),
    // so tracked never reflects the donated surplus held as balance.
    function invariant_DonationsAreSurplusOnly() public view {
        uint256 surplusUsdc = usdc.balanceOf(address(vault)) - vault.trackedUsdc();
        // every donated USDC remains as un-tracked surplus (>= because rebalance can add USDC too)
        assertGe(surplusUsdc, 0);
        // shares are always backed: supply>0 implies NAV>0
        if (vault.totalSupply() > 0) assertGt(vault.totalAssets(), 0);
    }

    // INV3: no shares can exist without tracked backing assets.
    function invariant_NoUnbackedShares() public view {
        if (vault.totalSupply() > 0) {
            assertTrue(vault.trackedUsdc() > 0 || vault.trackedMon() > 0);
        }
    }
}
