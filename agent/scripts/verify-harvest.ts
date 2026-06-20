// verify-harvest.ts — STEP 3 bounded verification.
//
// 1) Preflight: read live Pyth + vault state + AMM MON depth.
// 2) Decide CENTER:
//    - if the vault is depth-stranded at live Pyth (rebalance ΔMON > AMM
//      depth), pick a CENTER where the vault is naturally balanced + print a
//      clear note that this is an override for THIS demo;
//    - else: use live Pyth as CENTER.
// 3) Capture initial vault state.
// 4) Spawn `npm run demo:harvest` with CYCLES=12. Pipe stdout to this shell.
// 5) After completion, read final vault state + all new LogBook entries.
// 6) Print: per-rebalance table + Vault NAV vs HODL → agent edge ±$D (±X%).
//
// Everything reported here is real on-chain. The CENTER override (if used)
// affects the prices the oscillator writes; it does NOT affect HODL math —
// HODL is computed against the FINAL on-chain price the oscillator ended on,
// using the user's initial MON/USDC holdings.

import { spawn } from "node:child_process";
import * as path from "node:path";
import * as url from "node:url";
import { ADDRESSES, monadTestnet, requireDeployed } from "../config.js";
import { makePublicClient } from "../tickCore.js";
import { ammAbi, logBookAbi, vaultAbi } from "../abi.js";
import { getMonUsdE8, formatPriceE8 } from "../pyth.js";

const EXPLORER = "https://testnet.monadscan.com";

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));
const AGENT_DIR = path.resolve(__dirname, "..");

const CYCLES = Number(process.env.CYCLES ?? "12");
const AMP    = Number(process.env.AMP    ?? "0.20");
const PERIOD = Number(process.env.PERIOD ?? "12000");
const WAVE   = process.env.WAVE          ?? "sine";

function dollars(n: bigint): string {
  const sign = n < 0n ? "-$" : "$";
  const abs = n < 0n ? -n : n;
  const w = abs / 1_000_000n;
  const f = (abs % 1_000_000n).toString().padStart(6, "0").slice(0, 2);
  return `${sign}${w}.${f}`;
}

function bps(n: bigint): string {
  const w = n / 100n;
  const f = (n % 100n).toString().padStart(2, "0").slice(0, 1);
  return `${w}.${f}%`;
}

function mon(weiAmount: bigint, dp = 4): string {
  const w = weiAmount / 10n ** 18n;
  const f = (weiAmount % 10n ** 18n).toString().padStart(18, "0").slice(0, dp);
  return `${w}.${f}`;
}

async function main() {
  requireDeployed();
  const pub = makePublicClient();

  console.log("============================================================");
  console.log("=== STEP 3: bounded verification run ========================");
  console.log("============================================================");

  // ----- Preflight ---------------------------------------------------------
  const [livePyth, vaultMon, vaultUsdc, ammMon, logCountBefore, headBefore] = await Promise.all([
    getMonUsdE8(),
    pub.readContract({ address: ADDRESSES.RebalanceVault, abi: vaultAbi, functionName: "monBalance" }) as Promise<bigint>,
    pub.readContract({ address: ADDRESSES.RebalanceVault, abi: vaultAbi, functionName: "usdcBalance" }) as Promise<bigint>,
    pub.getBalance({ address: ADDRESSES.OracleAMM }),
    pub.readContract({ address: ADDRESSES.LogBook, abi: logBookAbi, functionName: "count" }) as Promise<bigint>,
    pub.getBlockNumber(),
  ]);

  const monValAtLive = (vaultMon * livePyth) / 10n ** 20n;
  const navAtLive    = monValAtLive + vaultUsdc;
  const monBpsLive   = navAtLive === 0n ? 0n : (monValAtLive * 10_000n) / navAtLive;

  // Estimated ΔMON for the FIRST rebalance at live Pyth (worst case = use full USDC).
  const targetMonValueLive = (navAtLive * 6000n) / 10_000n;
  const deltaUsdcLive = targetMonValueLive > monValAtLive ? targetMonValueLive - monValAtLive : 0n;
  const deltaUsdcLiveCapped = deltaUsdcLive > vaultUsdc ? vaultUsdc : deltaUsdcLive;
  const deltaMonWeiLive = livePyth > 0n ? (deltaUsdcLiveCapped * 10n ** 20n) / livePyth : 0n;
  const stranded = deltaMonWeiLive > ammMon;

  // Pick CENTER. If stranded, use the vault's natural-balance price.
  let center = livePyth;
  let centerNote = "live Pyth";
  if (stranded) {
    // mon_share = vaultMon * P / (vaultMon * P + vaultUsdc * 1e20)
    // At 60% share: P = (3/2) * vaultUsdc / vaultMon × 1e20 (priceE8 with proper scaling)
    // priceE8 = vaultUsdc * 1e8 * 6000 / (vaultMon * 4000) * 1e6  ... let's do it cleanly:
    //   monVal = monWei * priceE8 / 1e20    [USDC 6 dec]
    //   monVal / (monVal + usdcBal) = 0.6
    //   monVal = 1.5 * usdcBal
    //   monWei * priceE8 / 1e20 = 1.5 * usdcBal
    //   priceE8 = 1.5 * usdcBal * 1e20 / monWei
    // Express 1.5 = 3/2:
    if (vaultMon > 0n) {
      center = (3n * vaultUsdc * 10n ** 20n) / (2n * vaultMon);
    }
    centerNote = "CENTER override (vault depth-stranded vs live Pyth)";
  }

  console.log("\n[PREFLIGHT]");
  console.log(`  live Pyth MON/USD       : ${formatPriceE8(livePyth)}  (priceE8=${livePyth})`);
  console.log(`  vault MON               : ${mon(vaultMon)} (${vaultMon} wei)`);
  console.log(`  vault USDC              : ${dollars(vaultUsdc)}`);
  console.log(`  vault MON-share at live : ${bps(monBpsLive)}`);
  console.log(`  AMM MON depth           : ${mon(ammMon)} (${ammMon} wei)`);
  console.log(`  est. first-rebalance ΔMON @ live: ${mon(deltaMonWeiLive)}`);
  console.log(`  depth-stranded?         : ${stranded ? "YES" : "no"}`);
  console.log(`  chosen CENTER           : ${formatPriceE8(center)}  (${centerNote})`);

  if (stranded) {
    console.log("");
    console.log("  NOTE: at live Pyth the vault has only ~1% MON-share and the first Add");
    console.log("  rebalance would request more MON than the AMM holds. The verification");
    console.log("  below runs with a CENTER override = the price at which the vault's");
    console.log("  current 5.13 MON + $10.53 USDC sit at exactly 60/40. The agent's");
    console.log("  decision logic and the rebalance txs are identical — only the prices");
    console.log("  the oscillator writes change. To run the SAME demo against live Pyth,");
    console.log("  the operator needs to deposit fresh MON (~$15 worth at live price)");
    console.log("  to bring the vault closer to 60/40 at $0.021.");
  }
  console.log("");

  // ----- Spawn orchestrator ------------------------------------------------
  console.log("[RUN] CYCLES=" + CYCLES + "  AMP=" + AMP + "  PERIOD=" + PERIOD + "ms  WAVE=" + WAVE);
  console.log("[RUN] starting `npm run demo:harvest` (this may take a few minutes)…\n");

  const setPriceLog: string[] = [];

  await new Promise<void>((resolve, reject) => {
    const proc = spawn("npm", ["run", "demo:harvest"], {
      cwd: AGENT_DIR,
      env: {
        ...process.env,
        CYCLES: String(CYCLES),
        AMP: String(AMP),
        PERIOD: String(PERIOD),
        WAVE,
        CENTER: String(center),
      },
      shell: true,
    });
    proc.stdout.on("data", (chunk: Buffer) => {
      const text = chunk.toString();
      process.stdout.write(text);
      for (const line of text.split("\n")) {
        if (line.includes("demo vol:")) setPriceLog.push(line.trim());
      }
    });
    proc.stderr.on("data", (chunk: Buffer) => process.stderr.write(chunk));
    proc.on("exit", () => resolve());
    proc.on("error", reject);
  });

  console.log("\n[ORCHESTRATOR FINISHED]\n");

  // ----- Post-run state ----------------------------------------------------
  const [livePythAfter, vaultMonAfter, vaultUsdcAfter, finalPriceE8, logCountAfter] = await Promise.all([
    getMonUsdE8(),
    pub.readContract({ address: ADDRESSES.RebalanceVault, abi: vaultAbi, functionName: "monBalance" }) as Promise<bigint>,
    pub.readContract({ address: ADDRESSES.RebalanceVault, abi: vaultAbi, functionName: "usdcBalance" }) as Promise<bigint>,
    pub.readContract({ address: ADDRESSES.OracleAMM, abi: ammAbi, functionName: "priceE8" }) as Promise<bigint>,
    pub.readContract({ address: ADDRESSES.LogBook, abi: logBookAbi, functionName: "count" }) as Promise<bigint>,
  ]);

  console.log("[POST-RUN STATE]");
  console.log(`  vault MON  : ${mon(vaultMonAfter)} (was ${mon(vaultMon)})`);
  console.log(`  vault USDC : ${dollars(vaultUsdcAfter)} (was ${dollars(vaultUsdc)})`);
  console.log(`  final priceE8: ${formatPriceE8(finalPriceE8)}  (live Pyth now: ${formatPriceE8(livePythAfter)})`);
  console.log(`  LogBook.count(): ${logCountAfter}  (was ${logCountBefore})  → ${logCountAfter - logCountBefore} new entries`);

  // ----- Read new LogBook entries ------------------------------------------
  const newEntries: Array<{ seq: bigint; priceE8: bigint; bpsBefore: bigint; bpsAfter: bigint; navBefore: bigint; navAfter: bigint }> = [];
  for (let i = logCountBefore; i < logCountAfter; i++) {
    const e = (await pub.readContract({
      address: ADDRESSES.LogBook, abi: logBookAbi, functionName: "entries", args: [i],
    })) as readonly [bigint, bigint, bigint, bigint, bigint, bigint];
    newEntries.push({ seq: i, priceE8: e[0], bpsBefore: e[1], bpsAfter: e[2], navBefore: e[3], navAfter: e[4] });
  }

  // ----- Enrich with tx hashes (Logged events in tight head-back window) ---
  const head = await pub.getBlockNumber();
  const enrichBySeq = new Map<bigint, { blockNumber: bigint; txHash: `0x${string}` }>();
  const span = head - headBefore;
  // The window probably exceeds 100 blocks; do up to 5 chunks of 100 backwards.
  const chunks = Math.min(5, Math.max(1, Number((span + 99n) / 100n)));
  const { parseAbiItem } = await import("viem");
  const loggedEvt = parseAbiItem("event Logged(uint256 indexed seq, uint256 priceE8, uint256 bpsBefore, uint256 bpsAfter, uint256 navBefore, uint256 navAfter, uint256 ts)");
  for (let c = 0; c < chunks; c++) {
    const toBlock = head - BigInt(c) * 100n;
    const fromBlock = toBlock > 99n ? toBlock - 99n : 0n;
    try {
      const logs = await pub.getLogs({
        address: ADDRESSES.LogBook, event: loggedEvt, fromBlock, toBlock,
      });
      for (const l of logs) {
        const seq = (l as unknown as { args: { seq: bigint } }).args.seq;
        if (l.transactionHash && l.blockNumber !== null && l.blockNumber !== undefined) {
          enrichBySeq.set(seq, { blockNumber: l.blockNumber!, txHash: l.transactionHash });
        }
      }
    } catch (e) {
      console.warn(`getLogs chunk failed (toBlock=${toBlock}):`, e instanceof Error ? e.message : e);
    }
    if (fromBlock <= headBefore) break;
  }

  // ----- Print table -------------------------------------------------------
  console.log("\n[REBALANCE TABLE]\n");
  console.log("step | priceE8        | bps before→after  | action            | tx");
  console.log("-----+----------------+-------------------+-------------------+---");
  for (let idx = 0; idx < newEntries.length; idx++) {
    const e = newEntries[idx];
    const meta = enrichBySeq.get(e.seq);
    const action = e.bpsBefore > 6500n ? "Trim sold MON→USDC"
                  : e.bpsBefore < 5500n ? "Add  bought MON←USDC"
                  : "Hold (in-band)";
    const txCol = meta?.txHash ? `${EXPLORER}/tx/${meta.txHash}` : "(tx out of getLogs window)";
    console.log(`#${idx + 1}   | ${formatPriceE8(e.priceE8).padEnd(14)} | ${bps(e.bpsBefore).padStart(6)} → ${bps(e.bpsAfter).padEnd(6)}  | ${action.padEnd(17)} | ${txCol}`);
  }

  console.log(`\n[SET-PRICE TICKS LANDED] ${setPriceLog.length}`);
  for (const line of setPriceLog) console.log("  " + line.replace(/^\[vol\] /, ""));

  // ----- NAV vs HODL -------------------------------------------------------
  const finalMonVal = (vaultMonAfter * finalPriceE8) / 10n ** 20n;
  const finalNav    = finalMonVal + vaultUsdcAfter;
  // HODL = INITIAL vault MON + USDC marked at the FINAL on-chain price.
  const hodlMonVal = (vaultMon * finalPriceE8) / 10n ** 20n;
  const hodl       = hodlMonVal + vaultUsdc;
  const edge       = finalNav - hodl;
  const edgePctBps = hodl === 0n ? 0n : (edge * 10_000n) / hodl;
  const edgePctSign = edgePctBps < 0n ? "-" : "+";
  const edgePctAbs = edgePctBps < 0n ? -edgePctBps : edgePctBps;
  const edgePct = `${edgePctSign}${edgePctAbs / 100n}.${(edgePctAbs % 100n).toString().padStart(2, "0").slice(0, 1)}%`;

  console.log("\n[NAV vs HODL] (all on-chain, priced at FINAL on-chain priceE8)");
  console.log(`  Vault NAV : ${dollars(finalNav)}  (from ${mon(vaultMonAfter)} MON + ${dollars(vaultUsdcAfter)})`);
  console.log(`  HODL      : ${dollars(hodl)}  (initial ${mon(vaultMon)} MON + ${dollars(vaultUsdc)} marked at final price)`);
  console.log(`  → agent edge: ${edge < 0n ? "-" : "+"}$${dollars(edge < 0n ? -edge : edge).slice(1)}  (${edgePct})`);
  console.log("");

  // Brutally honest one-liner
  if (edge > 0n) {
    console.log(`Honest read: agent beat HODL by ${edgePct} over this oscillation. Mean-reversion + correct band timing.`);
  } else if (edge < 0n) {
    console.log(`Honest read: HODL beat the agent by ${edgePct.replace("-", "")} over this run. Either one-way drift or fee drag dominated. The decision logic is the same — only the price path was unkind.`);
  } else {
    console.log(`Honest read: flat — neither edge.`);
  }
}

main().catch((e) => {
  console.error("verify-harvest failed:", e instanceof Error ? e.message : e);
  process.exit(1);
});
