import type { Hash } from "viem";
import {
  TARGET, PYTH_CONTRACT, POLL_MS, KEEPER_PUSH_MS,
  monadTestnet, getAgentAccount, requireDeployed, requireP4Deployed,
} from "./config.js";
import { makePublicClient, makeWalletClient } from "./tickCore.js";
import { pythAbi, pythReaderAbi, hardenedVaultAbi } from "./abiHardened.js";
import { getMonUsdUpdate } from "./pythUpdate.js";
import { planSwap, buildRouterCalldata, type Portfolio } from "./hardenedTick.js";
import { decide, formatBps } from "./strategy.js";
import { formatPriceE8 } from "./pyth.js";
import { acquireWriterLock, installExitHooks, releaseWriterLock } from "./scripts/_lock.js";

// run.ts — live agent loop for the P4 AllocatorVault on Monad testnet.
//
// Each cycle (every POLL_MS):
//   1. pull fresh STABLE-Hermes update data + parsed price (read-only)
//   2. read tracked base (MON/USDC) + paused from the AllocatorVault
//   3. decide the 60/40 action (cost gate: hold unless MON share is outside the band)
//   4. PUSH price on-chain via PythPriceReaderP4.updatePrice{value:fee} when EITHER
//        - a rebalance is due (need a fresh on-chain price first), OR
//        - the keeper interval elapsed (KEEPER_PUSH_MS) — so readPriceE8 never goes stale
//   5. if off-band, rebalance() the AllocatorVault (which writes a LogBookP4 entry)
//
// One writer only (file lock), clean SIGINT/SIGTERM shutdown, survives bad cycles.
// AGENT_PK signs everything. No private keys are read by the web bundle.
//
// NOTE: the decision engine currently covers the core 60/40 rebalance leg. LP
// range-shift and parked-vault rotation are additional agent actions to be wired
// into the decision logic in a follow-up; the keeper push keeps the P4 oracle
// fresh regardless.

const ZERO = "0x0000000000000000000000000000000000000000";

function msg(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

async function main() {
  requireDeployed();
  requireP4Deployed();

  // Single-writer lock — the agent is the only price/rebalance writer for P4.
  acquireWriterLock("agent-loop");
  const { shouldStop } = installExitHooks(() => {
    console.log("[agent] draining — current cycle finishes, then exit.");
  });

  const agent  = getAgentAccount();
  const pub    = makePublicClient();
  const wallet = makeWalletClient(agent);

  const vault  = TARGET.vault;
  const reader = TARGET.reader;
  const router = TARGET.swapRouter;

  if (PYTH_CONTRACT.toLowerCase() === ZERO) throw new Error("PYTH_CONTRACT unset (config.pythContract)");
  if (reader.toLowerCase() === ZERO) throw new Error("PythPriceReaderP4 unset");

  console.log(`[agent] live loop · target=${TARGET.set}`);
  console.log(`[agent]   agent=${agent.address}`);
  console.log(`[agent]   vault=${vault}  reader=${reader}  router=${router}`);
  console.log(`[agent]   poll=${POLL_MS}ms  keeper=push at least every ${(KEEPER_PUSH_MS / 60_000).toFixed(1)}min`);

  let lastPushAt = 0; // ms epoch of the last successful on-chain push (0 = never)

  // MAX_CYCLES > 0 caps the loop to N iterations then exits cleanly (used for a
  // single capped test cycle). 0/unset = run continuously.
  const MAX_CYCLES = Number(process.env.MAX_CYCLES ?? 0);
  let cycles = 0;

  while (!shouldStop()) {
    try {
      // 1) fresh stable-Hermes update data + parsed price (read-only)
      const upd = await getMonUsdUpdate();

      // 2) tracked base + paused from the allocator
      const [monWei, usdc6, paused] = await Promise.all([
        pub.readContract({ address: vault, abi: hardenedVaultAbi, functionName: "trackedMon" }) as Promise<bigint>,
        pub.readContract({ address: vault, abi: hardenedVaultAbi, functionName: "trackedUsdc" }) as Promise<bigint>,
        pub.readContract({ address: vault, abi: hardenedVaultAbi, functionName: "paused" }) as Promise<boolean>,
      ]);
      const portfolio: Portfolio = { monWei, usdc6, source: "HardenedVault" };

      // 3) decide on the off-chain parsed price (== what readPriceE8 returns post-push)
      const monVal = (monWei * upd.priceE8) / 10n ** 20n; // 6 dec
      const nav = monVal + usdc6;
      const bpsBefore = nav === 0n ? 0n : (monVal * 10_000n) / nav;
      const decision = decide(bpsBefore);
      const needRebalance = !paused && nav > 0n && decision.action !== "hold";

      // 4) keeper gate — push if a rebalance is due OR the keeper interval elapsed
      const sincePush = lastPushAt === 0 ? Number.POSITIVE_INFINITY : Date.now() - lastPushAt;
      const keeperDue = sincePush >= KEEPER_PUSH_MS;
      const doPush = needRebalance || keeperDue;

      let pushTx: Hash | undefined;
      let pushReason = "";
      let onChainPrice: bigint | undefined;

      if (doPush) {
        const fee = (await pub.readContract({
          address: PYTH_CONTRACT, abi: pythAbi, functionName: "getUpdateFee", args: [upd.updateData],
        })) as bigint;
        // No fixed gas: viem estimates (and reverts a doomed tx BEFORE sending,
        // instead of wasting a full out-of-gas tx on-chain).
        pushTx = await wallet.writeContract({
          address: reader, abi: pythReaderAbi, functionName: "updatePrice",
          args: [upd.updateData], value: fee,
          chain: monadTestnet, account: agent, type: "legacy",
        });
        const pushRcpt = await pub.waitForTransactionReceipt({ hash: pushTx, pollingInterval: 500 });
        if (pushRcpt.status !== "success") throw new Error(`price push reverted on-chain (tx ${pushTx})`);
        lastPushAt = Date.now();
        pushReason = needRebalance ? "rebalance" : "keeper";
        onChainPrice = (await pub.readContract({
          address: reader, abi: pythReaderAbi, functionName: "readPriceE8",
        })) as bigint;
      }

      // 5) rebalance if off-band (cost gate). Uses the FRESH on-chain price.
      let rebalanceTx: Hash | undefined;
      if (needRebalance && router.toLowerCase() !== ZERO) {
        const price = onChainPrice ?? upd.priceE8;
        const plan = planSwap(portfolio, price);
        if (plan) {
          const calldata = buildRouterCalldata(plan.monToUsdc, plan.grossOut, plan.amountIn);
          try {
            // No fixed gas → viem estimates and throws on a doomed tx pre-send
            // (e.g. router can't fill), so we never burn a full out-of-gas tx.
            rebalanceTx = await wallet.writeContract({
              address: vault, abi: hardenedVaultAbi, functionName: "rebalance",
              args: [router, calldata, plan.monToUsdc, plan.amountIn],
              chain: monadTestnet, account: agent, type: "legacy",
            });
            const rcpt = await pub.waitForTransactionReceipt({ hash: rebalanceTx, pollingInterval: 500 });
            if (rcpt.status !== "success") {
              console.warn(`[agent] rebalance reverted on-chain (tx ${rebalanceTx})`);
              rebalanceTx = undefined;
            }
          } catch (e) {
            // Rebalance can revert (router liquidity, slippage cap). Keep the loop
            // and the price push alive; just report it.
            console.warn(`[agent] rebalance skipped — would revert: ${msg(e)}`);
            rebalanceTx = undefined;
          }
        }
      }

      // 6) one log line per cycle
      const parts: string[] = [
        `[tick] MON/USD=${formatPriceE8(onChainPrice ?? upd.priceE8)}`,
        `share=${formatBps(bpsBefore)}`,
        `action=${decision.action}`,
      ];
      parts.push(doPush
        ? `push(${pushReason})=${pushTx}`
        : `push=skip(${Math.round(sincePush / 1000)}s/${Math.round(KEEPER_PUSH_MS / 1000)}s)`);
      if (rebalanceTx) parts.push(`rebalance=${rebalanceTx} (LogBook+1)`);
      if (paused) parts.push("PAUSED(no rebalance; price still pushed)");
      console.log(parts.join("  "));
    } catch (e) {
      console.warn(`[agent] cycle error (continuing): ${msg(e)}`);
    }

    cycles++;
    if (MAX_CYCLES > 0 && cycles >= MAX_CYCLES) {
      console.log(`[agent] reached MAX_CYCLES=${MAX_CYCLES} — stopping (no continuous loop).`);
      break;
    }

    // sleep POLL_MS, but wake early on shutdown
    const t0 = Date.now();
    while (!shouldStop() && Date.now() - t0 < POLL_MS) {
      await new Promise((r) => setTimeout(r, Math.min(200, POLL_MS - (Date.now() - t0))));
    }
  }

  console.log("[agent] stopped.");
  releaseWriterLock();
}

main().catch((e) => {
  console.error("[agent] fatal:", msg(e));
  releaseWriterLock();
  process.exit(1);
});
