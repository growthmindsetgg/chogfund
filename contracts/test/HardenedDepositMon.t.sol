// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HardenedVault, ILogBook} from "../src/HardenedVault.sol";
import {PythPriceReader} from "../src/PythPriceReader.sol";
import {IPyth, PythStructs} from "../src/interfaces/IPyth.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// ───────────────────────── test doubles ─────────────────────────

contract TUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract MockLogBook is ILogBook {
    uint256 public count;
    function record(uint256, uint256, uint256, uint256, uint256) external { count++; }
}

/// MockPyth that models update-then-mint: `updatePriceFeeds` REFRESHES the stored
/// price's publishTime to `block.timestamp` (as a real fresh VAA would), so a deposit
/// that pushes fresh data un-stales the feed. `set()` stages the price; staleness +
/// confidence behaviour mirror the real contract.
contract MockPyth is IPyth {
    mapping(bytes32 => PythStructs.Price) internal _p;
    bytes32 public lastId;
    uint256 public fee = 1;
    uint256 public updateCalls;

    function set(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 pt) external {
        _p[id] = PythStructs.Price(price, conf, expo, pt);
        lastId = id;
    }
    function setFee(uint256 f) external { fee = f; }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythStructs.Price memory) {
        PythStructs.Price memory p = _p[id];
        require(p.publishTime != 0, "PriceFeedNotFound");
        require(block.timestamp - p.publishTime <= age, "StalePrice");
        return p;
    }
    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) { return _p[id]; }
    function getUpdateFee(bytes[] calldata) external view returns (uint256) { return fee; }

    function updatePriceFeeds(bytes[] calldata) external payable virtual {
        require(msg.value >= fee, "InsufficientFee");
        updateCalls++;
        // a fresh VAA brings a current publishTime — refresh the staged feed.
        _p[lastId].publishTime = block.timestamp;
    }
}

/// MockPyth whose updatePriceFeeds reenters the vault — proves nonReentrant.
contract ReentrantPyth is MockPyth {
    HardenedVault public vault;
    bool armed;
    function arm(HardenedVault v) external { vault = v; armed = true; }
    function updatePriceFeeds(bytes[] calldata) external payable override {
        require(msg.value >= fee, "InsufficientFee");
        _p[lastId].publishTime = block.timestamp;
        if (armed) {
            armed = false; // one-shot
            bytes[] memory u = new bytes[](1); u[0] = hex"00";
            vault.depositMON{value: 1e18}(u, address(0xBEEF)); // should revert (guard)
        }
    }
}

// ───────────────────────── fixture ─────────────────────────

contract DepositMonFixture is Test {
    TUSDC usdc;
    MockPyth pyth;
    PythPriceReader reader;
    MockLogBook logbook;
    HardenedVault vault;

    bytes32 constant FEED = 0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address agent = address(0xA9E37);
    address alice = address(0x1111);
    uint256 constant NOW = 1_782_000_000;
    uint256 constant MAX_AGE = 3600;
    uint256 constant CONF_BPS = 100; // 1%

    bytes[] UPD; // dummy Hermes update data (mock ignores content)

    function _deploy(MockPyth pythImpl) internal {
        vm.warp(NOW);
        usdc = new TUSDC();
        pyth = pythImpl;
        reader = new PythPriceReader(IPyth(address(pyth)), FEED, MAX_AGE, CONF_BPS);
        logbook = new MockLogBook();
        vault = new HardenedVault(IERC20(address(usdc)), reader, ILogBook(address(logbook)), agent, 50);
        UPD.push(hex"00");
    }

    // MON/USD ~ $0.02 (priceE8 = 2_000_000) by default.
    function _setPrice(int64 e8, uint64 conf) internal {
        pyth.set(FEED, e8, conf, int32(-8), block.timestamp);
    }

    function _seedDeadShares(uint256 amt) internal {
        usdc.mint(address(0xF00D), amt);
        vm.startPrank(address(0xF00D));
        usdc.approve(address(vault), amt);
        vault.deposit(amt, DEAD);
        vm.stopPrank();
    }

    function _depositUsdc(address who, uint256 amt) internal returns (uint256) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        uint256 s = vault.deposit(amt, who);
        vm.stopPrank();
        return s;
    }

    // hand-computed _convertToShares(assets, Floor) = assets * (supply + 1e6) / (totalAssets + 1)
    function _expectedShares(uint256 assets) internal view returns (uint256) {
        return Math.mulDiv(assets, vault.totalSupply() + 1e6, vault.totalAssets() + 1, Math.Rounding.Floor);
    }
}

// ───────────────────────── tests ─────────────────────────

contract DepositMonTest is DepositMonFixture {
    function setUp() public {
        _deploy(new MockPyth());
        _seedDeadShares(1e6);     // production inflation seed (1 USDC)
        _setPrice(2_000_000, 1_000); // $0.02/MON, 5bps conf
    }

    // (1) correct shares for a MON deposit at a known price.
    function test_DepositMON_CorrectShares_KnownPrice() public {
        uint256 monIn = 3e18; // 3 MON
        uint256 fee = pyth.fee();
        uint256 monValue = monIn * 2_000_000 / 1e20; // = 60_000 (6-dec) = $0.06

        uint256 expShares = _expectedShares(monValue);
        uint256 navBefore = vault.totalAssets();

        vm.deal(alice, monIn + fee);
        vm.prank(alice);
        uint256 got = vault.depositMON{value: monIn + fee}(UPD, alice);

        assertEq(monValue, 60_000, "monValue math");
        assertEq(got, expShares, "shares != hand-computed _convertToShares");
        assertEq(vault.balanceOf(alice), expShares, "minted to receiver");
        assertEq(vault.trackedMon(), monIn, "trackedMon += monIn");
        assertEq(vault.totalAssets(), navBefore + monValue, "NAV rose by exactly monValue");
        assertEq(address(vault).balance, monIn, "native MON held by vault (fee left)");
    }

    // (2a) a stale price (no refresh) reverts on read.
    function test_StalePrice_ReadReverts() public {
        _setPrice(2_000_000, 1_000);
        vm.warp(NOW + MAX_AGE + 1);
        vm.expectRevert(bytes("StalePrice"));
        reader.readPriceE8();
    }

    // (2b) update-then-mint REFRESHES a would-be-stale price → deposit succeeds.
    function test_DepositMON_RefreshesStale_Succeeds() public {
        _setPrice(2_000_000, 1_000);               // published at NOW
        vm.warp(NOW + MAX_AGE + 5_000);            // now stale (no update)

        // sanity: reading without an update reverts stale
        vm.expectRevert(bytes("StalePrice"));
        reader.readPriceE8();

        // deposit pushes fresh data first → readPriceE8 inside succeeds → mint
        uint256 monIn = 1e18;
        vm.deal(alice, monIn + pyth.fee());
        vm.prank(alice);
        uint256 got = vault.depositMON{value: monIn + pyth.fee()}(UPD, alice);
        assertGt(got, 0, "deposit should mint after fresh push");
        assertEq(pyth.updateCalls(), 1, "exactly one on-chain push");
    }

    // (3) low-confidence price reverts (refresh keeps conf, only bumps time).
    function test_DepositMON_RevertsOnLowConfidence() public {
        // conf/price = 30000/2000000 = 150 bps > 100 bps threshold
        _setPrice(2_000_000, 30_000);
        uint256 monIn = 1e18;
        uint256 fee = pyth.fee();
        uint256 val = monIn + fee;
        vm.deal(alice, val);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PythPriceReader.ConfidenceTooLow.selector, uint64(30_000), uint64(2_000_000), CONF_BPS)
        );
        vault.depositMON{value: val}(UPD, alice);
    }

    // (3b) deposit not leaving any MON after the fee reverts ZeroDeposit.
    function test_DepositMON_RevertsWhenValueLeqFee() public {
        uint256 fee = pyth.fee();
        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert(HardenedVault.ZeroDeposit.selector);
        vault.depositMON{value: fee}(UPD, alice); // value == fee → monIn 0
    }

    // (4) first MON deposit at NAV=0 mints sanely (no div-by-zero, virtual-offset guard).
    function test_DepositMON_FirstDeposit_NavZero() public {
        // fresh vault, NO dead shares, NO usdc → totalAssets()=0, totalSupply()=0
        _deploy(new MockPyth());
        _setPrice(2_000_000, 1_000);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);

        uint256 monIn = 1e18;            // 1 MON → monValue = 20_000 (6-dec) = $0.02
        uint256 monValue = monIn * 2_000_000 / 1e20;
        // _convertToShares(monValue, Floor) = monValue * (0 + 1e6) / (0 + 1)
        uint256 exp = monValue * 1e6;

        vm.deal(alice, monIn + pyth.fee());
        vm.prank(alice);
        uint256 got = vault.depositMON{value: monIn + pyth.fee()}(UPD, alice);
        assertEq(got, exp, "first-deposit shares (virtual offset)");
        assertEq(vault.totalAssets(), monValue, "NAV == monValue");
    }

    // (5) reentrancy: a malicious pyth that reenters depositMON is blocked by nonReentrant.
    function test_DepositMON_ReentrancyGuarded() public {
        ReentrantPyth rp = new ReentrantPyth();
        _deploy(rp);
        _seedDeadShares(1e6);
        _setPrice(2_000_000, 1_000);
        rp.arm(vault);

        uint256 monIn = 1e18;
        uint256 fee = rp.fee();
        uint256 val = monIn + fee;
        vm.deal(alice, val);
        vm.deal(address(rp), 2e18); // fund the reentry so it REACHES the guard (not OOF)
        vm.prank(alice);
        vm.expectRevert(); // ReentrancyGuardReentrantCall bubbles up
        vault.depositMON{value: val}(UPD, alice);
    }

    // (5b) shares mint to a contract receiver with NO callback / NO native sent to it.
    function test_DepositMON_NoNativeToReceiver() public {
        address recv = address(new MockLogBook()); // arbitrary contract, no payable hooks
        uint256 monIn = 1e18;
        vm.deal(alice, monIn + pyth.fee());
        vm.prank(alice);
        vault.depositMON{value: monIn + pyth.fee()}(UPD, recv);
        assertGt(vault.balanceOf(recv), 0, "shares minted to contract receiver");
        assertEq(recv.balance, 0, "no native MON sent to receiver");
    }

    // (6) USDC deposit path is byte-for-byte unchanged (regression).
    function test_USDC_DepositPath_Unchanged() public {
        uint256 amt = 500e6;
        uint256 trackedBefore = vault.trackedUsdc();
        uint256 expShares = vault.previewDeposit(amt);
        uint256 got = _depositUsdc(alice, amt);
        assertEq(got, expShares, "USDC deposit shares == previewDeposit");
        assertEq(vault.trackedUsdc(), trackedBefore + amt, "trackedUsdc += assets");
        assertEq(vault.trackedMon(), 0, "USDC deposit adds no MON");
    }

    // (7) MON deposit does NOT dilute: share price unchanged, NAV up exactly monValue.
    function test_MonDeposit_NoDilution_SharePriceUnchanged() public {
        _depositUsdc(alice, 1000e6); // establish a real share price

        uint256 navBefore = vault.totalAssets();
        uint256 ppsBefore = vault.convertToAssets(1e12); // assets per 1e12 shares

        uint256 monIn = 5e18;
        uint256 monValue = monIn * 2_000_000 / 1e20;
        address bob = address(0x2222);
        vm.deal(bob, monIn + pyth.fee());
        vm.prank(bob);
        vault.depositMON{value: monIn + pyth.fee()}(UPD, bob);

        assertEq(vault.totalAssets(), navBefore + monValue, "NAV rose by exactly monValue");
        // share price unchanged within 1 micro-asset (floor rounding favours the pool)
        assertApproxEqAbs(vault.convertToAssets(1e12), ppsBefore, 1, "share price moved (dilution)");
        // bob's shares are worth ~ what he put in (<= monValue by floor rounding)
        uint256 bobAssets = vault.convertToAssets(vault.balanceOf(bob));
        assertApproxEqAbs(bobAssets, monValue, 2, "bob over/under-credited");
    }

    // (8) agent cannot depositMON.
    function test_DepositMON_AgentBlocked() public {
        vm.deal(agent, 2e18);
        vm.prank(agent);
        vm.expectRevert(HardenedVault.AgentBlocked.selector);
        vault.depositMON{value: 2e18}(UPD, agent);
    }
}
