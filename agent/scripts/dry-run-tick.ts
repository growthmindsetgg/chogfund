import { makePublicClient } from "../tickCore.js";
import { hardenedTick, formatHardenedTick, planSwap, type Portfolio } from "../hardenedTick.js";
import { ADDRESSES, PYTH_CONTRACT, PYTH_HERMES_URL, MON_USD_FEED_ID, RPC_URL, SLIPPAGE_BPS } from "../config.js";

// Read-only dry-run of one hardened-vault tick. Sends NO state-changing tx.
// Proves the full price path end-to-end (Hermes → fee → on-chain accept) and
// prints the intended 60/40 action + computed minOut.
async function main() {
  console.log("=== Chog Vault — hardened tick DRY-RUN (read-only, no tx) ===");
  console.log(`RPC:           ${RPC_URL}`);
  console.log(`Pyth contract: ${PYTH_CONTRACT}`);
  console.log(`Hermes:        ${PYTH_HERMES_URL}`);
  console.log(`MON/USD feed:  ${MON_USD_FEED_ID}`);
  console.log(`HardenedVault: ${ADDRESSES.HardenedVault}  (zero ⇒ portfolio read from legacy vault)`);
  console.log("");

  const pub = makePublicClient();
  const r = await hardenedTick({ publicClient: pub }, { dryRun: true, verifyOnChainRead: true });
  console.log(formatHardenedTick(r));

  if (!r.ok) process.exit(1);

  // Illustrative: if the live portfolio is in-band, show what the swap + minOut
  // WOULD be for an off-band (80% MON) book at the same live price, so the
  // minOut derivation is visible.
  if (r.decision?.action === "hold" && r.priceE8) {
    // MON-heavy book at the live price (~$0.02): ~$40 MON + $10 USDC ⇒ ~80% MON ⇒ trim.
    const monWei = (40_000_000n * 10n ** 20n) / r.priceE8; // wei MON worth ~$40
    const synthetic: Portfolio = { monWei, usdc6: 10_000_000n, source: "HardenedVault" };
    const plan = planSwap(synthetic, r.priceE8);
    console.log("");
    console.log("--- illustrative off-band plan (synthetic MON-heavy ~80% book, live price) ---");
    if (plan) {
      console.log(
        `  direction: ${plan.monToUsdc ? "MON→USDC (trim)" : "USDC→MON (buy)"}  amountIn=${plan.amountIn}` +
        `  grossOut=${plan.grossOut}  minOut=${plan.minOut}  (slippage cap ${SLIPPAGE_BPS} bps)`,
      );
    } else {
      console.log("  (synthetic book unexpectedly in-band)");
    }
  }
}

main().catch((e) => {
  console.error("dry-run fatal:", e instanceof Error ? e.message : e);
  process.exit(1);
});
