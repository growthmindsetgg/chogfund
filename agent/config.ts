import "dotenv/config";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { privateKeyToAccount } from "viem/accounts";
import { defineChain, type Hex } from "viem";

const here = dirname(fileURLToPath(import.meta.url));

export interface Addresses {
  chainId: number;
  rpc: string;
  rpcFallback?: string;
  explorerBase: string;
  MockUSDC: `0x${string}`;
  OracleAMM: `0x${string}`;
  LogBook: `0x${string}`;
  RebalanceVault: `0x${string}`;
  PythPriceReader?: `0x${string}`;
  HardenedVault?: `0x${string}`;
  swapRouter?: `0x${string}`;
  LogBookP3?: `0x${string}`;
  // P4 allocator set (live-loop target). Mocks/config sub-objects intentionally untyped.
  p4?: {
    AllocatorVault: `0x${string}`;
    LpManager: `0x${string}`;
    VaultRouter: `0x${string}`;
    HealthMonitor: `0x${string}`;
    PythPriceReaderP4: `0x${string}`;
    LogBookP4: `0x${string}`;
    swapRouter: `0x${string}`;
  };
  _retired?: string[];
  agent: `0x${string}`;
  demoUser: `0x${string}`;
  deployer: `0x${string}`;
  deployBlock: number;
  pythContract?: `0x${string}`;
  pythHermes?: string;
  pythHermesBeta: string;
  monUsdFeedId: string;
  monUsdFeedIdBeta?: string;
  slippageBps?: number;
  maxAgeSec?: number;
  confThresholdBps?: number;
}

export const ADDRESSES: Addresses = JSON.parse(
  readFileSync(resolve(here, "../config/addresses.json"), "utf8")
) as Addresses;

const ZERO = "0x0000000000000000000000000000000000000000";

// Throw early if Phase 4 hasn't run yet. Callers that just want addresses
// (e.g. pyth-probe) can wrap-import this; the agent loop refuses to start
// against zero addresses.
export function requireDeployed(): void {
  for (const k of ["MockUSDC", "OracleAMM", "LogBook", "RebalanceVault"] as const) {
    if (ADDRESSES[k].toLowerCase() === ZERO) {
      throw new Error(`config/addresses.json has zero ${k}. Run Phase 4 deploy first.`);
    }
  }
}

// ── P4 live-loop target ──────────────────────────────────────────────────────
// The agent loop drives the P4 AllocatorVault: pushes price through
// PythPriceReaderP4 and rebalances the AllocatorVault (which writes LogBookP4).
// We resolve the active target from the p4 block, falling back to P3/P1 so the
// loop still has SOMETHING to point at on older configs.
export const P4 = ADDRESSES.p4;

export const TARGET = {
  vault:      (P4?.AllocatorVault    ?? ADDRESSES.HardenedVault ?? ADDRESSES.RebalanceVault) as `0x${string}`,
  reader:     (P4?.PythPriceReaderP4 ?? ADDRESSES.PythPriceReader ?? ZERO) as `0x${string}`,
  swapRouter: (P4?.swapRouter        ?? ADDRESSES.swapRouter ?? ZERO) as `0x${string}`,
  logBook:    (P4?.LogBookP4         ?? ADDRESSES.LogBookP3 ?? ADDRESSES.LogBook) as `0x${string}`,
  set: (P4 ? "P4-AllocatorVault" : ADDRESSES.HardenedVault ? "P3-HardenedVault" : "P1-RebalanceVault") as string,
} as const;

// The live loop refuses to start unless the P4 allocator + its reader are set.
export function requireP4Deployed(): void {
  if (!P4 || P4.AllocatorVault.toLowerCase() === ZERO || P4.PythPriceReaderP4.toLowerCase() === ZERO) {
    throw new Error("config/addresses.json has no p4.AllocatorVault / p4.PythPriceReaderP4. Run the P4 deploy first.");
  }
}

// RPC override (env beats addresses.json).
export const RPC_URL: string = process.env.RPC_URL ?? ADDRESSES.rpc;

// Pyth — STABLE network on Monad testnet (verified in P3 STEP 1: the on-chain
// Pyth contract accepts stable VAAs; beta is rejected with InvalidWormholeVaa).
export const PYTH_HERMES_URL: string =
  process.env.PYTH_HERMES_URL ?? ADDRESSES.pythHermes ?? ADDRESSES.pythHermesBeta;
export const MON_USD_FEED_ID: string = process.env.MON_USD_FEED_ID ?? ADDRESSES.monUsdFeedId;
export const PYTH_CONTRACT: `0x${string}` =
  (process.env.PYTH_CONTRACT ?? ADDRESSES.pythContract ?? ZERO) as `0x${string}`;

// On-chain safety params (mirror the contract defaults; agent uses for off-chain quoting).
export const SLIPPAGE_BPS: bigint = BigInt(process.env.SLIPPAGE_BPS ?? ADDRESSES.slippageBps ?? 50);

// Loop cadence — how often the loop reads price/portfolio and decides.
export const POLL_MS: number = Number(process.env.POLL_MS ?? 10_000);

// Pyth keeper cadence — the loop pushes a fresh price on-chain AT LEAST this
// often even when no rebalance is due, so readPriceE8 never goes stale. Default
// 10 min — well under the 48h reader maxAge, and a comfortable freshness margin.
export const KEEPER_PUSH_MS: number = Number(process.env.KEEPER_PUSH_MS ?? 10 * 60_000);

// Monad testnet chain. Multicall left undefined on purpose (testnet has no Multicall3).
export const monadTestnet = defineChain({
  id: ADDRESSES.chainId,
  name: "Monad Testnet",
  nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: "MonadScan", url: ADDRESSES.explorerBase } },
  testnet: true,
});

// Keys — DO NOT import these from the web bundle.
function asHexPk(name: string, raw: string | undefined): Hex {
  if (!raw) throw new Error(`${name} not set in env`);
  const v = raw.startsWith("0x") ? raw : (`0x${raw}` as const);
  if (v.length !== 66) throw new Error(`${name} must be a 32-byte hex private key`);
  return v as Hex;
}

export function getAgentAccount() {
  return privateKeyToAccount(asHexPk("AGENT_PK", process.env.AGENT_PK));
}

export function getDeployerAccount() {
  return privateKeyToAccount(asHexPk("DEPLOYER_PK", process.env.DEPLOYER_PK));
}
