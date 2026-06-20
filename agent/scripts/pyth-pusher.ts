import { ADDRESSES, POLL_MS, getDeployerAccount, monadTestnet, requireDeployed } from "../config.js";
import { makePublicClient, makeWalletClient } from "../tickCore.js";
import { ammAbi } from "../abi.js";
import { getMonUsdE8, formatPriceE8 } from "../pyth.js";
import { acquireWriterLock, installExitHooks, releaseWriterLock } from "./_lock.js";

// Pushes live MON/USD from Pyth Beta Hermes onto OracleAMM.setPrice every POLL_MS.
// Signed by DEPLOYER_PK (owner). Skip-and-continue on any failure.
//
// Shares the single-writer lock with price-driver.ts — refuses to start if the
// oscillator (or another pusher) is already running.
async function main() {
  requireDeployed();
  acquireWriterLock("pyth-pusher");

  const deployer = getDeployerAccount();
  const pub      = makePublicClient();
  const wallet   = makeWalletClient(deployer);

  const { shouldStop } = installExitHooks(() => {
    // No exit-resync — pusher's whole purpose IS to track live Pyth, so when
    // it stops the oracle is already at the latest live value.
  });

  console.log(`[pyth-pusher] deployer=${deployer.address}  amm=${ADDRESSES.OracleAMM}  poll=${POLL_MS}ms`);

  while (!shouldStop()) {
    try {
      const priceE8 = await getMonUsdE8();
      const txHash = await wallet.writeContract({
        address: ADDRESSES.OracleAMM, abi: ammAbi, functionName: "setPrice",
        args: [priceE8],
        chain: monadTestnet, account: deployer,
        gas: 120_000n, type: "legacy",
      });
      await pub.waitForTransactionReceipt({ hash: txHash, pollingInterval: 500 });
      console.log(`pyth MON/USD = ${formatPriceE8(priceE8)} → setPrice tx ${txHash}`);
    } catch (e) {
      console.warn("[pyth-pusher] skipped cycle:", e instanceof Error ? e.message : e);
    }

    // Sleep with early-exit on shutdown.
    const tStart = Date.now();
    while (!shouldStop() && Date.now() - tStart < POLL_MS) {
      await new Promise((r) => setTimeout(r, Math.min(200, POLL_MS - (Date.now() - tStart))));
    }
  }

  console.log("[pyth-pusher] stopped.");
  releaseWriterLock();
}

main().catch((e) => {
  console.error("[pyth-pusher] fatal:", e instanceof Error ? e.message : e);
  releaseWriterLock();
  process.exit(1);
});
