// price-driver.ts — DEMO HARVEST oscillator.
//
// Honest framing: the agent's decision logic is real and autonomous. Real MON
// is flat over a short demo, so we INJECT volatility via this owner-signed
// price oscillator on the live Monad testnet so the agent has something to
// harvest. Every rebalance the agent fires is a real on-chain tx + LogBook
// entry. Rebalancing nets positive only when swings beat the 0.3% AMM fee AND
// the price mean-reverts; on a one-way move it lags HODL.
//
// IMPORTANT: do NOT run scripts/pyth-pusher.ts at the same time — two writers
// fight over OracleAMM.setPrice and the agent sees whichever landed last.
//
// Env (with defaults):
//   AMP     0.20    ±20% amplitude around center
//   PERIOD  12000   ms between ticks (one "quarter-swing")
//   CYCLES  12      number of ticks before STOP. 0 or <0 = unbounded.
//   WAVE    sine    sine | triangle
//   CENTER  (live)  override priceE8 center. If unset, read live Pyth beta once.

import { ADDRESSES, getDeployerAccount, monadTestnet, requireDeployed } from "../config.js";
import { makePublicClient, makeWalletClient } from "../tickCore.js";
import { ammAbi } from "../abi.js";
import { getMonUsdE8, formatPriceE8 } from "../pyth.js";

const AMP    = Number(process.env.AMP    ?? "0.20");
const PERIOD = Number(process.env.PERIOD ?? "12000");
const CYCLES = Number(process.env.CYCLES ?? "12");
const WAVE   = (process.env.WAVE ?? "sine").toLowerCase();

function waveFn(theta: number): number {
  if (WAVE === "triangle") {
    // Exact triangle in [-1, 1] with period 2π.
    return (2 / Math.PI) * Math.asin(Math.sin(theta));
  }
  return Math.sin(theta);
}

async function main() {
  requireDeployed();
  if (!(AMP > 0 && AMP < 0.9)) {
    throw new Error(`AMP out of safe range: ${AMP} (expected (0, 0.9))`);
  }
  if (WAVE !== "sine" && WAVE !== "triangle") {
    throw new Error(`WAVE must be sine|triangle, got ${WAVE}`);
  }

  // Center price — live Pyth by default so we oscillate around the REAL number.
  const envCenter = process.env.CENTER;
  let center: bigint;
  if (envCenter && envCenter.trim() !== "") {
    center = BigInt(envCenter);
    console.log(`[demo-harvest] CENTER override: priceE8=${center} (${formatPriceE8(center)})`);
  } else {
    console.log(`[demo-harvest] reading live Pyth beta MON/USD as center…`);
    center = await getMonUsdE8();
    console.log(`[demo-harvest] center=${center} (${formatPriceE8(center)})  <- live Pyth`);
  }

  const deployer = getDeployerAccount();
  const pub      = makePublicClient();
  const wallet   = makeWalletClient(deployer);

  const unbounded = !(CYCLES > 0);
  console.log(`[demo-harvest] AMP=${AMP} (±${(AMP * 100).toFixed(0)}%)  WAVE=${WAVE}  PERIOD=${PERIOD}ms  CYCLES=${unbounded ? "∞" : CYCLES}`);
  console.log(`[demo-harvest] deployer=${deployer.address}  amm=${ADDRESSES.OracleAMM}`);
  console.log(`[demo-harvest] (do NOT run pyth-pusher concurrently — same setPrice slot)`);

  let i = 0;
  let theta = 0;
  while (unbounded || i < CYCLES) {
    const w   = waveFn(theta);                     // -1 .. 1
    const mult = 1 + AMP * w;                      // 0.8 .. 1.2 at AMP=0.20
    // Fixed-point conversion: priceE8 = round(center * mult).
    // BigInt(round(mult * 1e6)) keeps 6 sig figs of mult; price precision
    // stays at ~8 dec (priceE8 has 8 decimals; mult precision 1e-6 → priceE8
    // error ≤ 1 LSB at this center).
    const multScaled = BigInt(Math.round(mult * 1_000_000));
    const priceE8 = (center * multScaled) / 1_000_000n;

    const pct  = ((mult - 1) * 100).toFixed(1);
    const sign = mult >= 1 ? "+" : "";

    try {
      const tx = await wallet.writeContract({
        address: ADDRESSES.OracleAMM, abi: ammAbi, functionName: "setPrice",
        args: [priceE8], chain: monadTestnet, account: deployer,
        gas: 120_000n, type: "legacy",
      });
      await pub.waitForTransactionReceipt({ hash: tx, pollingInterval: 500 });
      console.log(`demo vol: MON ${formatPriceE8(priceE8)} (${sign}${pct}% vs center) → setPrice tx ${tx}`);
    } catch (e) {
      console.warn(`[demo-harvest] skip tick i=${i}:`, e instanceof Error ? e.message : e);
    }

    theta += Math.PI / 2; // one quarter-swing per tick
    i++;
    if (!unbounded && i >= CYCLES) break;
    await new Promise((r) => setTimeout(r, PERIOD));
  }
  console.log(`[demo-harvest] STOP after ${i} iterations.`);
}

main().catch((e) => {
  console.error("[demo-harvest] fatal:", e instanceof Error ? e.message : e);
  process.exit(1);
});
