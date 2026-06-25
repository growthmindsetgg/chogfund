// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AllocatorVault} from "../src/AllocatorVault.sol";
import {LpManager} from "../src/LpManager.sol";
import {VaultRouter} from "../src/VaultRouter.sol";
import {MockUniV3Pool} from "../src/MockUniV3Pool.sol";
import {MockUniV3PositionManager} from "../src/MockUniV3PositionManager.sol";
import {MockERC4626Vault} from "../src/MockERC4626Vault.sol";
import {PythPriceReader} from "../src/PythPriceReader.sol";

interface IMintableUSDC is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// =====================================================================
///  P4 E2E — full allocator lifecycle on Monad testnet (MOCKS).
/// =====================================================================
///  deposit -> rebalance into base MON -> allocate LP -> park USDC + MON ->
///  accrue LP fees + parked yield -> collect fees -> shift LP range ->
///  STRESS flee primary->backup -> EMERGENCY pull-all-to-base -> withdraw.
///  Accounting (NAV breakdown) is logged at every step.
///
///  ⚠️  MOCKS. Real Uniswap CL math / real vault behavior / real slippage+liquidity /
///  real LP valuation are validated at the MAINNET CANARY (P7). The on-chain price is
///  held at the trustless Pyth value throughout (no keeper on testnet), so price-move /
///  IL dynamics are covered by the local fuzz+invariant suite, not here.
contract E2EP4 is Script {
    address constant USDC   = 0xAcA4F378d7b10228e83Ab7a6A38547484789EA9a;
    address constant ROUTER = 0x890aBBe3BF290a70727d138860aD33f50ECC82eF;
    int24   constant SPACING = 60;

    struct A {
        AllocatorVault vault;
        LpManager lp;
        VaultRouter vr;
        MockUniV3Pool pool;
        MockUniV3PositionManager npm;
        MockERC4626Vault usdcA;
        MockERC4626Vault usdcB;
        MockERC4626Vault monA;
        PythPriceReader reader;
        address wmon;
    }

    function _load() internal view returns (A memory a) {
        a.vault = AllocatorVault(payable(vm.envAddress("P4_ALLOCATOR_VAULT")));
        a.lp = LpManager(vm.envAddress("P4_LPMANAGER"));
        a.vr = VaultRouter(vm.envAddress("P4_VAULT_ROUTER"));
        a.pool = MockUniV3Pool(vm.envAddress("P4_POOL"));
        a.npm = MockUniV3PositionManager(vm.envAddress("P4_NPM"));
        a.usdcA = MockERC4626Vault(vm.envAddress("P4_USDC_A"));
        a.usdcB = MockERC4626Vault(vm.envAddress("P4_USDC_B"));
        a.monA = MockERC4626Vault(vm.envAddress("P4_MON_A"));
        a.reader = PythPriceReader(vm.envAddress("P4_READER"));
        a.wmon = vm.envAddress("P4_WMON");
    }

    function run() external {
        uint256 dpk = vm.envUint("DEPLOYER_PK");
        uint256 apk = vm.envUint("AGENT_PK");
        address user = vm.addr(dpk);
        A memory a = _load();
        uint256 priceE8 = a.reader.readPriceE8();
        console2.log("priceE8 ($/MON, 8d):", priceE8);

        // 1) deposit 20 USDC (user)
        vm.startBroadcast(dpk);
        IMintableUSDC(USDC).mint(user, 20e6);
        IERC20(USDC).approve(address(a.vault), 20e6);
        a.vault.deposit(20e6, user);
        vm.stopBroadcast();
        _log(a, "1) after deposit 20 USDC");

        // 2) agent: rebalance ~0.04 USDC into base MON, allocate LP, park USDC + MON
        (int24 lo, int24 hi) = _range(a.pool, 6000);
        vm.startBroadcast(apk);
        {
            uint256 amountIn = 0.04e6;
            uint256 grossMon = amountIn * 1e20 / priceE8;
            bytes memory cd = abi.encodeWithSignature(
                "swap(address,address,uint256,uint256)", USDC, address(0), amountIn, grossMon
            );
            a.vault.rebalance(ROUTER, cd, false, amountIn);
        }
        a.vault.allocateToLp(0.8e18, 1e6, lo, hi);
        a.vault.parkUsdc(address(a.usdcA), 5e6);
        a.vault.parkMon(address(a.monA), 0.3e18);
        vm.stopBroadcast();
        _log(a, "2) after rebalance + allocate LP + park");

        // 3) operator: accrue LP trading fees + parked yield (mock signals)
        vm.startBroadcast(dpk);
        a.npm.accrueFees(a.lp.tokenId(), 0.01e18, 0.05e6); // (WMON fee0, USDC fee1) — WMON is token0
        IMintableUSDC(USDC).mint(user, 0.25e6);
        IERC20(USDC).approve(address(a.usdcA), 0.25e6);
        a.usdcA.accrueYield(0.25e6);
        vm.stopBroadcast();
        _log(a, "3) after LP fee + parked yield accrual");

        // 4) agent: collect LP fees to base, shift LP range
        (int24 lo2, int24 hi2) = _range(a.pool, 3000);
        vm.startBroadcast(apk);
        a.vault.collectLpFees();
        a.vault.shiftLpRange(lo2, hi2);
        vm.stopBroadcast();
        _log(a, "4) after collect fees + shift range");

        // 5) operator pushes usdcA into STRESS, agent flees A -> B
        vm.startBroadcast(dpk);
        a.usdcA.setStress(9500, false, 10_000);
        vm.stopBroadcast();
        vm.startBroadcast(apk);
        a.vault.fleeToBackup(address(a.usdcA), address(a.usdcB), a.vr.sharesOf(address(a.usdcA)));
        vm.stopBroadcast();
        _log(a, "5) after STRESS flee usdcA -> usdcB");

        // 6) operator pauses usdcB (EMERGENCY), agent pulls ALL parked to base
        vm.startBroadcast(dpk);
        a.usdcB.setStress(0, true, 10_000);
        vm.stopBroadcast();
        vm.startBroadcast(apk);
        a.vault.emergencyExitAll(address(a.usdcB));
        vm.stopBroadcast();
        _log(a, "6) after EMERGENCY exit all parked -> base");

        // 7) user withdraws everything (unwinds remaining LP + base, pro-rata)
        vm.startBroadcast(dpk);
        uint256 shares = a.vault.balanceOf(user);
        (uint256 uOut, uint256 mOut) = a.vault.redeemInKind(shares, user);
        vm.stopBroadcast();
        console2.log("7) withdraw -> USDC out (6d):", uOut);
        console2.log("   withdraw -> MON  out (wei):", mOut);
        _log(a, "7) after withdraw");
    }

    function _range(MockUniV3Pool pool, int24 width) internal view returns (int24 lo, int24 hi) {
        (, int24 tick, , , , , ) = pool.slot0();
        int24 center = (tick / SPACING) * SPACING; // align to tick spacing
        lo = center - width;
        hi = center + width;
    }

    function _log(A memory a, string memory tag) internal view {
        (uint256 bu, uint256 bm, uint256 legs, uint256 total) = a.vault.navBreakdown();
        (uint256 lpv, uint256 parked) = a.vault.legBreakdown();
        console2.log(tag);
        console2.log("   baseUSDC(6d) / baseMONval(6d):", bu, bm);
        console2.log("   LP leg(6d)   / parked leg(6d):", lpv, parked);
        console2.log("   NAV total(6d):", total);
        console2.log("   sum check (base+legs == total):", bu + bm + legs == total);
        console2.log("   lp tokenId / parked A shares / parked B shares:",
            a.lp.tokenId(), a.vr.sharesOf(address(a.usdcA)), a.vr.sharesOf(address(a.usdcB)));
    }
}
