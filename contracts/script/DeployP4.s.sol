// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {PythPriceReader} from "../src/PythPriceReader.sol";
import {LogBook} from "../src/LogBook.sol";
import {MockWMON} from "../src/MockWMON.sol";
import {MockUniV3Pool} from "../src/MockUniV3Pool.sol";
import {MockUniV3PositionManager} from "../src/MockUniV3PositionManager.sol";
import {LpManager} from "../src/LpManager.sol";
import {MockERC4626Vault} from "../src/MockERC4626Vault.sol";
import {VaultRouter} from "../src/VaultRouter.sol";
import {HealthMonitor} from "../src/HealthMonitor.sol";
import {AllocatorVault, IWMON} from "../src/AllocatorVault.sol";
import {HardenedVault, ILogBook} from "../src/HardenedVault.sol";
import {INonfungiblePositionManager} from "../src/external/uniswap/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "../src/external/uniswap/IUniswapV3Pool.sol";
import {TickMath} from "../src/external/uniswap/TickMath.sol";
import {FullMath} from "../src/external/uniswap/FullMath.sol";

interface IMintableUSDC is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// =====================================================================
///  P4 DEPLOY — ALLOCATOR + ALL MOCKS (Monad testnet, MOCKS ONLY).
/// =====================================================================
///  Deploys the extended allocator (AllocatorVault) plus the faithful-interface
///  MOCKS it drives: MockUniV3 pair, MockUniV3PositionManager, 4x MockERC4626
///  (USDC primary+backup, MON primary+backup), VaultRouter, HealthMonitor, a fresh
///  PythPriceReader (real on-chain Pyth) and a fresh LogBook. Reuses MockUSDC and
///  the P3 MockSwapRouter.
///
///  ⚠️  These are MOCKS. Real Uniswap concentrated-liquidity math, real ERC4626 vault
///  behavior, real slippage/liquidity, and real LP valuation are validated at the
///  MAINNET CANARY (P7). Mock-green here is NOT real-integration green.
///
///  The mock pool is initialized to the price IMPLIED BY the trustless on-chain Pyth
///  MON/USD price, so the LP value path (Pyth-priced WMON leg) is internally
///  consistent. A demo-tolerant maxAge is used because the public testnet feed has no
///  active keeper (production reuses the P3 tight-maxAge + Hermes push flow).
///
///  Env: DEPLOYER_PK. Run:
///   forge script script/DeployP4.s.sol:DeployP4 --rpc-url <ankr> --broadcast --legacy
contract DeployP4 is Script {
    address constant PYTH        = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    bytes32 constant FEED        = 0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1;
    address constant USDC        = 0xAcA4F378d7b10228e83Ab7a6A38547484789EA9a;
    address constant AGENT       = 0xd461546Fcc49bcB73C78E9931FD64498ccEa48Ce;
    address constant SWAP_ROUTER = 0x890aBBe3BF290a70727d138860aD33f50ECC82eF; // reuse P3 mock router
    address constant DEAD        = 0x000000000000000000000000000000000000dEaD;

    uint256 constant MAX_AGE      = 172_800; // 48h — demo tolerance for the keeperless testnet feed
    uint256 constant CONF_BPS     = 100;
    uint256 constant SLIPPAGE_BPS = 50;
    uint24  constant FEE          = 3000;
    int24   constant SPACING      = 60;

    uint256 constant SEED_DEAD       = 1e6;        // 1 USDC dead shares
    uint256 constant ROUTER_MON_SEED = 1.5 ether;  // native MON liquidity for USDC->MON rebalance
    uint256 constant ROUTER_USDC_SEED= 100e6;      // USDC liquidity for MON->USDC rebalance
    uint256 constant PM_WMON_BUFFER  = 0.3 ether;  // WMON buffer for safe LP exits
    uint256 constant PM_USDC_BUFFER  = 5e6;        // USDC buffer for safe LP exits

    struct Dep {
        PythPriceReader reader;
        LogBook logbook;
        MockWMON wmon;
        MockUniV3Pool pool;
        MockUniV3PositionManager npm;
        LpManager lp;
        MockERC4626Vault usdcA;
        MockERC4626Vault usdcB;
        MockERC4626Vault monA;
        MockERC4626Vault monB;
        VaultRouter vr;
        HealthMonitor monitor;
        AllocatorVault vault;
        uint256 priceE8;
        bool usdcIsToken0;
        uint160 sqrtP;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);
        Dep memory d;

        vm.startBroadcast(pk);
        _deployCore(d, deployer);
        _deployLegs(d);
        _wire(d);
        _seed(d, deployer);
        vm.stopBroadcast();

        _report(d);
    }

    function _deployCore(Dep memory d, address deployer) internal {
        d.reader = new PythPriceReader(IPyth(PYTH), FEED, MAX_AGE, CONF_BPS);
        d.logbook = new LogBook(deployer);
        d.wmon = new MockWMON();

        d.priceE8 = d.reader.readPriceE8();
        d.usdcIsToken0 = USDC < address(d.wmon);
        (address t0, address t1) = d.usdcIsToken0 ? (USDC, address(d.wmon)) : (address(d.wmon), USDC);
        d.sqrtP = _sqrtPriceX96FromPriceE8(d.priceE8, d.usdcIsToken0);

        d.pool = new MockUniV3Pool(t0, t1, FEE, SPACING, d.sqrtP);
        d.npm = new MockUniV3PositionManager(d.pool);
        d.lp = new LpManager(
            INonfungiblePositionManager(address(d.npm)), IUniswapV3Pool(address(d.pool)), d.reader, address(d.wmon), USDC
        );
    }

    function _deployLegs(Dep memory d) internal {
        d.usdcA = new MockERC4626Vault(IERC20(USDC), "Chog USDC Vault A", "cuA");
        d.usdcB = new MockERC4626Vault(IERC20(USDC), "Chog USDC Vault B", "cuB");
        d.monA = new MockERC4626Vault(IERC20(address(d.wmon)), "Chog MON Vault A", "cmA");
        d.monB = new MockERC4626Vault(IERC20(address(d.wmon)), "Chog MON Vault B", "cmB");
        d.vr = new VaultRouter(IERC20(USDC), IERC20(address(d.wmon)), d.reader);
        d.monitor = new HealthMonitor(7000, 9000, 9700, 9000);
        d.vault = new AllocatorVault(
            IERC20(USDC), d.reader, ILogBook(address(d.logbook)), AGENT, SLIPPAGE_BPS, IWMON(address(d.wmon))
        );
    }

    function _wire(Dep memory d) internal {
        d.logbook.setVault(address(d.vault));
        d.vault.setLpManager(d.lp);
        d.lp.setVault(address(d.vault));
        d.vault.setVaultRouter(d.vr);
        d.vr.setVault(address(d.vault));
        d.vault.setHealthMonitor(d.monitor);
        d.vr.addUsdcVault(address(d.usdcA));
        d.vr.addUsdcVault(address(d.usdcB));
        d.vr.addMonVault(address(d.monA));
        d.vr.addMonVault(address(d.monB));
        d.vault.setRouterWhitelist(SWAP_ROUTER, true);
    }

    function _seed(Dep memory d, address deployer) internal {
        IMintableUSDC(USDC).mint(deployer, SEED_DEAD);
        IERC20(USDC).approve(address(d.vault), SEED_DEAD);
        d.vault.deposit(SEED_DEAD, DEAD);

        (bool ok, ) = SWAP_ROUTER.call{value: ROUTER_MON_SEED}("");
        require(ok, "router MON seed failed");
        IMintableUSDC(USDC).mint(SWAP_ROUTER, ROUTER_USDC_SEED);

        d.wmon.deposit{value: PM_WMON_BUFFER}();
        IERC20(address(d.wmon)).transfer(address(d.npm), PM_WMON_BUFFER);
        IMintableUSDC(USDC).mint(address(d.npm), PM_USDC_BUFFER);
    }

    function _report(Dep memory d) internal view {
        (, int24 tick, , , , , ) = d.pool.slot0();
        console2.log("P4_PRICE_E8=%s", d.priceE8);
        console2.log("P4_USDC_IS_TOKEN0=%s", d.usdcIsToken0);
        console2.log("P4_SQRTP=%s", uint256(d.sqrtP));
        console2.log("P4_POOL_TICK=%s", vm.toString(tick));
        console2.log("ADDR P4_WMON=%s", address(d.wmon));
        console2.log("ADDR P4_READER=%s", address(d.reader));
        console2.log("ADDR P4_LOGBOOK=%s", address(d.logbook));
        console2.log("ADDR P4_POOL=%s", address(d.pool));
        console2.log("ADDR P4_NPM=%s", address(d.npm));
        console2.log("ADDR P4_LPMANAGER=%s", address(d.lp));
        console2.log("ADDR P4_USDC_A=%s", address(d.usdcA));
        console2.log("ADDR P4_USDC_B=%s", address(d.usdcB));
        console2.log("ADDR P4_MON_A=%s", address(d.monA));
        console2.log("ADDR P4_MON_B=%s", address(d.monB));
        console2.log("ADDR P4_VAULT_ROUTER=%s", address(d.vr));
        console2.log("ADDR P4_HEALTH_MONITOR=%s", address(d.monitor));
        console2.log("ADDR P4_ALLOCATOR_VAULT=%s", address(d.vault));
        console2.log("P4 totalSupply (dead shares):", d.vault.totalSupply());
        console2.log("P4 totalAssets (USDC 6d):", d.vault.totalAssets());
    }

    /// @dev sqrtPriceX96 = sqrt(P_pool) * 2^96, where P_pool (token1/token0, raw) is
    ///      derived from the $/MON priceE8 + decimals/ordering:
    ///        WMON=token0: P_pool = priceE8 / 1e20
    ///        USDC=token0: P_pool = 1e20 / priceE8
    function _sqrtPriceX96FromPriceE8(uint256 priceE8, bool usdcIsToken0) internal pure returns (uint160) {
        uint256 Q192 = uint256(1) << 192;
        uint256 ratioX192 = usdcIsToken0
            ? FullMath.mulDiv(1e20, Q192, priceE8)
            : FullMath.mulDiv(priceE8, Q192, 1e20);
        uint256 s = _sqrt(ratioX192);
        require(s >= TickMath.MIN_SQRT_RATIO && s < TickMath.MAX_SQRT_RATIO, "sqrtP out of range");
        return uint160(s);
    }

    /// @dev Babylonian integer sqrt with a bit-length initial guess (OZ-style).
    function _sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 result = 1 << (_log2(a) >> 1);
        unchecked {
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            return result < a / result ? result : a / result;
        }
    }

    function _log2(uint256 x) internal pure returns (uint256 r) {
        unchecked {
            if (x >> 128 > 0) { x >>= 128; r += 128; }
            if (x >> 64 > 0) { x >>= 64; r += 64; }
            if (x >> 32 > 0) { x >>= 32; r += 32; }
            if (x >> 16 > 0) { x >>= 16; r += 16; }
            if (x >> 8 > 0) { x >>= 8; r += 8; }
            if (x >> 4 > 0) { x >>= 4; r += 4; }
            if (x >> 2 > 0) { x >>= 2; r += 2; }
            if (x >> 1 > 0) { r += 1; }
        }
    }
}
