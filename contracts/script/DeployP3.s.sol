// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {PythPriceReader} from "../src/PythPriceReader.sol";
import {HardenedVault, ILogBook} from "../src/HardenedVault.sol";
import {SafeSwapExecutor} from "../src/SafeSwapExecutor.sol";
import {MockSwapRouter} from "../src/MockSwapRouter.sol";
import {LogBook} from "../src/LogBook.sol";

interface IMintableUSDC is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// P3 deploy: PythPriceReader + fresh LogBook + MockSwapRouter + HardenedVault,
/// wired to the VERIFIED stable Pyth contract + MON/USD feed. Reuses MockUSDC.
/// A fresh LogBook is required — the existing one is permanently bound to the
/// retired vault (setVault is one-shot). The old OracleAMM is simply abandoned
/// (no on-chain action needed to retire it).
///
/// Env: DEPLOYER_PK (owner). Run:
///   forge script script/DeployP3.s.sol:DeployP3 --rpc-url monad --broadcast --legacy
contract DeployP3 is Script {
    // verified in P3 STEP 1
    address constant PYTH   = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    bytes32 constant FEED   = 0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1;
    address constant USDC   = 0xAcA4F378d7b10228e83Ab7a6A38547484789EA9a;
    address constant AGENT  = 0xd461546Fcc49bcB73C78E9931FD64498ccEa48Ce;

    uint256 constant MAX_AGE      = 60;
    uint256 constant CONF_BPS     = 100;
    uint256 constant SLIPPAGE_BPS = 50;

    uint256 constant SEED_DEAD     = 1e6;       // 1 USDC seeded to dead address
    uint256 constant ROUTER_USDC   = 1_000e6;   // mock-router USDC liquidity (free mint)
    // MON router liquidity is funded SEPARATELY from the agent account (13 MON) post-deploy,
    // because the deployer (1.83 MON) must reserve its balance for deployment gas (~1.2 MON).
    uint256 constant ROUTER_MON    = 0;
    address constant DEAD          = 0x000000000000000000000000000000000000dEaD;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        PythPriceReader reader = new PythPriceReader(IPyth(PYTH), FEED, MAX_AGE, CONF_BPS);
        LogBook logbook = new LogBook(deployer);
        MockSwapRouter router = new MockSwapRouter();
        HardenedVault vault =
            new HardenedVault(IERC20(USDC), reader, ILogBook(address(logbook)), AGENT, SLIPPAGE_BPS);

        // wire
        logbook.setVault(address(vault));
        vault.setRouterWhitelist(address(router), true);

        // seed dead shares (belt-and-suspenders inflation defense)
        IMintableUSDC(USDC).mint(deployer, SEED_DEAD);
        IERC20(USDC).approve(address(vault), SEED_DEAD);
        vault.deposit(SEED_DEAD, DEAD);

        // fund the mock router USDC liquidity (MON funded separately from agent post-deploy)
        IMintableUSDC(USDC).mint(address(router), ROUTER_USDC);
        if (ROUTER_MON > 0) {
            (bool ok, ) = address(router).call{value: ROUTER_MON}("");
            require(ok, "router MON fund failed");
        }

        vm.stopBroadcast();

        console2.log("PythPriceReader:", address(reader));
        console2.log("LogBook (fresh):", address(logbook));
        console2.log("MockSwapRouter :", address(router));
        console2.log("HardenedVault  :", address(vault));
        console2.log("vault.totalSupply (dead shares):", vault.totalSupply());
        console2.log("router USDC liq:", IERC20(USDC).balanceOf(address(router)));
        console2.log("router MON  liq:", address(router).balance);
    }
}
