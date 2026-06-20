// price-driver.ts — DEMO HARVEST oscillator. HARDENED.
//
// Honest framing: the agent's decision logic is real and autonomous. Real MON
// is flat over a short demo, so we INJECT volatility around the LIVE Pyth
// price via owner-signed setPrice on Monad testnet. Every rebalance the agent
// fires is a real on-chain tx + LogBook entry. Rebalancing nets positive only
// when swings beat the 0.3% AMM fee AND the price mean-reverts.
//
// HARDEN RULES:
//   1. CENTER defaults to a live Pyth fetch at start. An env CENTER override
//      is REJECTED if it sits more than 50% away from the live Pyth value
//      (guards against an accidental CENTER=2 leaving the oracle stuck at
//      the dollar-scale seed). The accepted center is logged as
//      "harvest centered on live Pyth $X" (or "$X override accepted").
//   2. On exit — after the last cycle AND on SIGINT/SIGBREAK/SIGTERM — the
//      script writes a final setPrice = current live Pyth so the oracle is
//      NEVER stranded at an oscillation trough.
//   3. The script acquires a single-writer lock at start; refuses to run if
//      pyth-pusher.ts or another price-driver instance is already holding it.
//
// Env (with defaults):
//   AMP     0.20    ±20% amplitude around center
//   PERIOD  12000   ms between ticks
//   CYCLES  12      number of ticks; <= 0 = unbounded
//   WAVE    sine    sine | triangle
//   CENTER  (live)  priceE8 override. If unset, reads live Pyth.

import { ADDRESSES, getDeployerAccount, monadTestnet, requireDeployed } from "../config.js";
import { makePublicClient, makeWalletClient } from "../tickCore.js";
import { ammAbi } from "../abi.js";
import { getMonUsdE8, formatPriceE8 } from "../pyth.js";
import { abs, acquireWriterLock, installExitHooks, releaseWriterLock } from "./_lock.js";
import type { WalletClient, Account, PublicClient } from "viem";

const AMP    = Number(process.env.AMP    ?? "0.20");
const PERIOD = Number(process.env.PERIOD ?? "12000");
const CYCLES = Number(process.env.CYCLES ?? "12");
const WAVE   = (process.env.WAVE ?? "sine").toLowerCase();

const CENTER_GUARD_FRACTION = 0.5; // 50% of live Pyth

function waveFn(theta: number): number {
  if (WAVE === "triangle") return (2 / Math.PI) * Math.asin(Math.sin(theta));
  return Math.sin(theta);
}

async function pushSetPrice(
  pub: PublicClient,
  wallet: WalletClient & { account: Account },
  deployer: Account,
  priceE8: bigint,
): Promise<`0x${string}`> {
  const tx = await wallet.writeContract({
    address: ADDRESSES.OracleAMM, abi: ammAbi, functionName: "setPrice",
    args: [priceE8], chain: monadTestnet, account: deployer,
    gas: 120_000n, type: "legacy",
  });
  await pub.waitForTransactionReceipt({ hash: tx, pollingInterval: 500 });
  return tx;
}

async function main() {
  requireDeployed();
  if (!(AMP > 0 && AMP < 0.9)) {
    throw new Error(`AMP out of safe range: ${AMP} (expected (0, 0.9))`);
  }
  if (WAVE !== "sine" && WAVE !== "triangle") {
    throw new Error(`WAVE must be sine|triangle, got ${WAVE}`);
  }

  // -- one-writer lock (rule 3) -------------------------------------------
  acquireWriterLock("price-driver");

  // -- decide center: live Pyth or guarded override (rule 1) ---------------
  console.log(`[demo-harvest] reading live Pyth beta MON/USD…`);
  const livePyth = await getMonUsdE8();
  const envCenter = process.env.CENTER;
  let center = livePyth;
  if (envCenter && envCenter.trim() !== "") {
    let proposed: bigint;
    try { proposed = BigInt(envCenter); }
    catch { throw new Error(`Invalid CENTER (not an integer): ${envCenter}`); }

    if (proposed <= 0n) {
      throw new Error(`CENTER must be > 0, got ${proposed}`);
    }
    const tolerance = (livePyth * BigInt(Math.round(CENTER_GUARD_FRACTION * 1000))) / 1000n;
    const drift = abs(proposed - livePyth);

    if (drift > tolerance) {
      console.warn(
        `[demo-harvest] CENTER override ${formatPriceE8(proposed)} REJECTED — ` +
        `drifts ${formatPriceE8(drift)} from live Pyth ${formatPriceE8(livePyth)} ` +
        `(threshold: ±${(CENTER_GUARD_FRACTION * 100).toFixed(0)}% of live). ` +
        `Falling back to live Pyth.`,
      );
      center = livePyth;
    } else {
      center = proposed;
      console.log(
        `[demo-harvest] CENTER override accepted: ${formatPriceE8(center)} ` +
        `(within ±${(CENTER_GUARD_FRACTION * 100).toFixed(0)}% of live Pyth ${formatPriceE8(livePyth)})`,
      );
    }
  }
  console.log(`[demo-harvest] harvest centered on live Pyth ${formatPriceE8(center)}` +
              `${center === livePyth ? "" : "  (override accepted)"}`);

  const deployer = getDeployerAccount();
  const pub      = makePublicClient();
  const wallet   = makeWalletClient(deployer);

  const unbounded = !(CYCLES > 0);
  console.log(`[demo-harvest] AMP=${AMP} (±${(AMP * 100).toFixed(0)}%)  WAVE=${WAVE}  PERIOD=${PERIOD}ms  CYCLES=${unbounded ? "∞" : CYCLES}`);
  console.log(`[demo-harvest] deployer=${deployer.address}  amm=${ADDRESSES.OracleAMM}`);

  // -- shared exit machinery (rule 2) --------------------------------------
  // resyncDone is set true after the normal-path resync, so a follow-up
  // beforeExit/SIGINT doesn't fire a second setPrice.
  let resyncDone = false;
  const doResync = async (label: string) => {
    if (resyncDone) return;
    resyncDone = true;
    try {
      const finalPrice = await getMonUsdE8();
      console.log(`[${label}] resyncing oracle to live Pyth ${formatPriceE8(finalPrice)}…`);
      const tx = await pushSetPrice(pub, wallet, deployer, finalPrice);
      console.log(`[${label}] resync setPrice tx ${tx}`);
    } catch (e) {
      console.error(`[${label}] resync failed:`, e instanceof Error ? e.message : e);
    }
  };
  const { shouldStop } = installExitHooks(() => doResync("exit"));

  // -- main oscillation loop -----------------------------------------------
  let i = 0;
  let theta = 0;

  while (!shouldStop() && (unbounded || i < CYCLES)) {
    const w   = waveFn(theta);
    const mult = 1 + AMP * w;
    const multScaled = BigInt(Math.round(mult * 1_000_000));
    const priceE8 = (center * multScaled) / 1_000_000n;
    const pct  = ((mult - 1) * 100).toFixed(1);
    const sign = mult >= 1 ? "+" : "";

    try {
      const tx = await pushSetPrice(pub, wallet, deployer, priceE8);
      console.log(`demo vol: MON ${formatPriceE8(priceE8)} (${sign}${pct}% vs center) → setPrice tx ${tx}`);
    } catch (e) {
      console.warn(`[demo-harvest] skip tick i=${i}:`, e instanceof Error ? e.message : e);
    }

    theta += Math.PI / 2;
    i++;
    if (!shouldStop() && (unbounded || i < CYCLES)) {
      // Sleep, but wake early if shutdown is requested.
      const tStart = Date.now();
      while (!shouldStop() && Date.now() - tStart < PERIOD) {
        await new Promise((r) => setTimeout(r, Math.min(200, PERIOD - (Date.now() - tStart))));
      }
    }
  }

  // -- exit-resync (rule 2, normal path) -----------------------------------
  await doResync("demo-harvest");

  console.log(`[demo-harvest] STOP after ${i} iterations.`);
  releaseWriterLock();
}

main().catch((e) => {
  console.error("[demo-harvest] fatal:", e instanceof Error ? e.message : e);
  releaseWriterLock();
  process.exit(1);
});
