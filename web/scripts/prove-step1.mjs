// P8 STEP 1 proof — exercises the SAME addresses.json + extracted ABIs the
// hooks use, via viem (the same lib wagmi/the hooks use). Prints each read so
// it can be diffed against independent `cast call` output.
//
// Run:  node web/scripts/prove-step1.mjs  (from repo root)  OR
//       node scripts/prove-step1.mjs      (from web/)
import { createPublicClient, http, fallback, defineChain } from "viem";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const j = (p) => JSON.parse(readFileSync(resolve(here, p), "utf8"));

const A = j("../src/addresses.json");
const allocatorAbi = j("../src/abis/AllocatorVault.json");
const readerAbi = j("../src/abis/PythPriceReader.json");
const logAbi = j("../src/abis/LogBook.json");
const usdcAbi = j("../src/abis/MockUSDC.json");

const chain = defineChain({
  id: A.chainId, name: "Monad Testnet",
  nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: [A.rpc] } },
});
const client = createPublicClient({
  chain,
  transport: fallback([http(A.rpc), http(A.rpcFallback)]),
  batch: { multicall: false },
});

const USER = A.demoUser;
const av = { address: A.AllocatorVault, abi: allocatorAbi };
const r = (fn, args) => client.readContract({ ...av, functionName: fn, args });

const usdc = (v) => `$${(Number(v) / 1e6).toFixed(6)}`;
const mon = (v) => `${(Number(v) / 1e18).toFixed(8)} MON`;
const e8 = (v) => `$${(Number(v) / 1e8).toFixed(8)}/MON`;

const out = {};
out.nav = await r("totalAssets");
out.totalShares = await r("totalSupply");
out.decimals = await r("decimals");
out.sharePrice = await r("convertToAssets", [10n ** BigInt(out.decimals)]);
out.paused = await r("paused");
out.owner = await r("owner");
out.agent = await r("agent");
out.trackedMon = await r("trackedMon");
out.trackedUsdc = await r("trackedUsdc");
const nb = await r("navBreakdown");
const lb = await r("legBreakdown");
out.baseUsdc = nb[0]; out.baseMonValue = nb[1]; out.legsValue = nb[2]; out.nbTotal = nb[3];
out.lpValue = lb[0]; out.parkedValue = lb[1];
out.lpManager = await r("lpManager");
out.vaultRouter = await r("vaultRouter");
out.healthMonitor = await r("healthMonitor");
out.priceE8 = await client.readContract({ address: A.PythPriceReader, abi: readerAbi, functionName: "readPriceE8" });
out.feedId = await client.readContract({ address: A.PythPriceReader, abi: readerAbi, functionName: "feedId" });
out.userShares = await client.readContract({ ...av, functionName: "balanceOf", args: [USER] });
out.userValue = out.userShares > 0n ? await r("previewRedeem", [out.userShares]) : 0n;
out.userUsdcBal = await client.readContract({ address: A.MockUSDC, abi: usdcAbi, functionName: "balanceOf", args: [USER] });
out.logCount = await client.readContract({ address: A.LogBookP4, abi: logAbi, functionName: "count" });
const newest = out.logCount > 0n
  ? await client.readContract({ address: A.LogBookP4, abi: logAbi, functionName: "entries", args: [out.logCount - 1n] })
  : null;

console.log("=== HOOK READ PATH (viem, via web/src/addresses.json + extracted ABIs) ===");
console.log("RPC                :", A.rpc, "(fallback", A.rpcFallback + ")");
console.log("AllocatorVault     :", A.AllocatorVault);
console.log("NAV (totalAssets)  :", out.nav.toString(), "=", usdc(out.nav));
console.log("totalSupply        :", out.totalShares.toString());
console.log("share decimals     :", out.decimals);
console.log("share price/1share :", out.sharePrice.toString(), "=", usdc(out.sharePrice));
console.log("paused             :", out.paused);
console.log("owner              :", out.owner);
console.log("agent              :", out.agent);
console.log("trackedMon         :", out.trackedMon.toString(), "=", mon(out.trackedMon));
console.log("trackedUsdc        :", out.trackedUsdc.toString(), "=", usdc(out.trackedUsdc));
console.log("--- allocation legs (sum must == NAV) ---");
console.log("baseUsdc           :", out.baseUsdc.toString(), "=", usdc(out.baseUsdc));
console.log("baseMonValue       :", out.baseMonValue.toString(), "=", usdc(out.baseMonValue));
console.log("lpValue            :", out.lpValue.toString(), "=", usdc(out.lpValue));
console.log("parkedValue        :", out.parkedValue.toString(), "=", usdc(out.parkedValue));
const sum = out.baseUsdc + out.baseMonValue + out.lpValue + out.parkedValue;
console.log("SUM legs           :", sum.toString(), "=", usdc(sum),
  sum === out.nav ? "  ✓ == NAV" : `  ✗ != NAV(${out.nav})`);
console.log("navBreakdown.total :", out.nbTotal.toString(), out.nbTotal === out.nav ? "✓" : "✗");
console.log("legsValue==lp+park :", (out.legsValue === out.lpValue + out.parkedValue) ? "✓" : "✗");
console.log("--- price ---");
console.log("readPriceE8        :", out.priceE8.toString(), "=", e8(out.priceE8));
console.log("reader feedId      :", out.feedId, out.feedId.toLowerCase() === A.monUsdFeedId.toLowerCase() ? "✓ == addresses.monUsdFeedId (STABLE)" : "✗ feed mismatch");
console.log("--- user position (" + USER + ") ---");
console.log("userShares         :", out.userShares.toString());
console.log("userValue          :", out.userValue.toString(), "=", usdc(out.userValue));
console.log("userUsdcBalance    :", out.userUsdcBal.toString(), "=", usdc(out.userUsdcBal));
console.log("--- proof feed ---");
console.log("LogBookP4 count    :", out.logCount.toString());
if (newest) {
  console.log("newest entry       : priceE8=" + newest[0] + " bps " + newest[1] + "→" + newest[2] +
    " nav " + usdc(newest[3]) + "→" + usdc(newest[4]) + " ts=" + newest[5]);
}

// Live Pyth (stable Hermes) — same source/feed the contract reads.
const url = new URL("/v2/updates/price/latest", A.pythHermes);
url.searchParams.append("ids[]", A.monUsdFeedId);
url.searchParams.set("parsed", "true");
const hb = await (await fetch(url)).json();
const hp = hb.parsed[0].price;
const liveE8 = BigInt(hp.price) * 10n ** BigInt(hp.expo + 8 >= 0 ? hp.expo + 8 : 0) /
  (hp.expo + 8 < 0 ? 10n ** BigInt(-(hp.expo + 8)) : 1n);
console.log("--- pyth reconciliation ---");
console.log("live Hermes (stable):", liveE8.toString(), "=", e8(liveE8), "feed", hb.parsed[0].id.slice(0, 18) + "…");
const driftBps = out.priceE8 > 0n
  ? (BigInt(Math.abs(Number(out.priceE8 - liveE8))) * 10000n) / liveE8 : 0n;
console.log("on-chain vs live    : drift " + (Number(driftBps) / 100).toFixed(2) + "%  (badge flags >2% as 'oracle syncing')");
