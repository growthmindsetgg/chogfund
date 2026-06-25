import { parseEventLogs } from "viem";
import { makePublicClient, makeWalletClient } from "../tickCore.js";
import { ADDRESSES, getAgentAccount, getDeployerAccount, monadTestnet } from "../config.js";
import { hardenedVaultAbi, pythReaderAbi, pythAbi } from "../abiHardened.js";
import { usdcAbi, logBookAbi } from "../abi.js";
import { getMonUsdUpdate } from "../pythUpdate.js";

const ZERO = "0x0000000000000000000000000000000000000000" as const;
const NATIVE = ZERO;

const VAULT = ADDRESSES.HardenedVault as `0x${string}`;
const READER = ADDRESSES.PythPriceReader as `0x${string}`;
const ROUTER = ADDRESSES.swapRouter as `0x${string}`;
const LOGBOOK = ADDRESSES.LogBookP3 as `0x${string}`;
const USDC = ADDRESSES.MockUSDC;

const DEPOSIT_USDC = 100_000n;       // 0.10 USDC
const ROUTER_MON_TARGET = 3n * 10n ** 18n; // ensure router holds >= 3 MON

async function main() {
  const pub = makePublicClient();
  const deployer = getDeployerAccount();   // demoUser / owner — NOT the agent
  const agent = getAgentAccount();
  const dW = makeWalletClient(deployer);
  const aW = makeWalletClient(agent);

  const log = (s: string) => console.log(s);
  const wait = async (hash: `0x${string}`) => {
    const r = await pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success") throw new Error(`tx ${hash} REVERTED on-chain`);
    return r;
  };

  log("=== STEP 7 e2e — hardened vault on Monad testnet ===");

  // 0b) Owner widens the price freshness window for testnet (Hermes lag + RPC latency).
  const maxAge = (await pub.readContract({ address: READER, abi: pythReaderAbi, functionName: "maxAge" })) as bigint;
  if (maxAge < 300n) {
    log(`\n[0b] owner setConfig maxAge ${maxAge} → 300s…`);
    const conf = (await pub.readContract({ address: READER, abi: pythReaderAbi, functionName: "confThresholdBps" })) as bigint;
    const h = await dW.writeContract({
      address: READER, abi: [{ type: "function", name: "setConfig", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [] }] as const,
      functionName: "setConfig", args: [300n, conf], chain: monadTestnet, account: deployer,
    });
    await wait(h);
    log(`    tx ${h}`);
  }

  // 0) Fund router MON liquidity from the AGENT (deployer reserves balance for gas).
  const rBal = (await pub.getBalance({ address: ROUTER }));
  if (rBal < ROUTER_MON_TARGET) {
    const need = ROUTER_MON_TARGET - rBal;
    log(`\n[0] funding router with ${need} wei MON (agent → router)…`);
    const h = await aW.sendTransaction({ to: ROUTER, value: need, chain: monadTestnet, account: agent });
    await wait(h);
    log(`    tx ${h}`);
  }
  log(`    router MON balance: ${await pub.getBalance({ address: ROUTER })} wei`);

  // 1) Deposit a small USDC amount as the demo user → expect shares minted.
  //    Idempotent: if the demo user already holds shares (from a prior run), skip.
  const sharesBefore = (await pub.readContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "balanceOf", args: [deployer.address] })) as bigint;
  if (sharesBefore > 0n) {
    log(`\n[1] deposit SKIPPED — demo user already holds ${sharesBefore} shares (resuming).`);
  } else {
    log(`\n[1] deposit ${DEPOSIT_USDC} (0.10 USDC) by ${deployer.address}…`);
    const mintTx = await dW.writeContract({
      address: USDC, abi: [{ type: "function", name: "mint", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [] }] as const,
      functionName: "mint", args: [deployer.address, DEPOSIT_USDC], chain: monadTestnet, account: deployer,
    });
    await wait(mintTx);
    const apprTx = await dW.writeContract({ address: USDC, abi: usdcAbi, functionName: "approve", args: [VAULT, DEPOSIT_USDC], chain: monadTestnet, account: deployer });
    await wait(apprTx);
    const depTx = await dW.writeContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "deposit", args: [DEPOSIT_USDC, deployer.address], chain: monadTestnet, account: deployer, gas: 300_000n });
    await wait(depTx);
    const sharesAfter = (await pub.readContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "balanceOf", args: [deployer.address] })) as bigint;
    log(`    deposit tx ${depTx}`);
    log(`    shares minted: ${sharesAfter - sharesBefore}  (balance ${sharesAfter})`);
  }

  // 2) Agent pushes a FRESH Pyth price on-chain via the reader.
  log(`\n[2] agent pushes fresh Pyth price…`);
  const upd = await getMonUsdUpdate();
  const fee = (await pub.readContract({ address: READER, abi: pythReaderAbi, functionName: "getUpdateFee", args: [upd.updateData] })) as bigint;
  const pushTx = await aW.writeContract({ address: READER, abi: pythReaderAbi, functionName: "updatePrice", args: [upd.updateData], value: fee, chain: monadTestnet, account: agent, gas: 2_000_000n });
  await wait(pushTx);
  const priceE8 = (await pub.readContract({ address: READER, abi: pythReaderAbi, functionName: "readPriceE8" })) as bigint;
  log(`    push tx ${pushTx}  (fee ${fee} wei)`);
  log(`    on-chain readPriceE8: ${priceE8}  (Hermes parsed: ${upd.priceE8}, conf ${upd.confBps} bps)`);

  // 3) Agent rebalance — partial BUY of ~1 MON through the whitelisted router.
  log(`\n[3] agent rebalance (buy ~1 MON via safe-swap path)…`);
  const amountIn = priceE8 / 100n;                  // USDC (6dp) to buy ~1 MON at the on-chain price
  const grossMon = (amountIn * 10n ** 20n) / priceE8; // router pays this (≥ contract minOut = gross*0.995)
  const minOutContract = (await pub.readContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "quoteMinOut", args: [USDC, amountIn, priceE8] })) as bigint;
  const swapData = (await import("viem")).encodeFunctionData({ abi: pythAbi, functionName: "swap", args: [USDC, NATIVE, amountIn, grossMon] });
  const logCountBefore = (await pub.readContract({ address: LOGBOOK, abi: logBookAbi, functionName: "count" })) as bigint;
  const tuBefore = (await pub.readContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "trackedUsdc" })) as bigint;
  const tmBefore = (await pub.readContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "trackedMon" })) as bigint;
  log(`    amountIn=${amountIn} USDC  grossOut=${grossMon} MON  contract minOut=${minOutContract}`);
  const rebTx = await aW.writeContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "rebalance", args: [ROUTER, swapData, false, amountIn], chain: monadTestnet, account: agent, gas: 800_000n });
  const rebRcpt = await wait(rebTx);
  const tuAfter = (await pub.readContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "trackedUsdc" })) as bigint;
  const tmAfter = (await pub.readContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "trackedMon" })) as bigint;
  const logCountAfter = (await pub.readContract({ address: LOGBOOK, abi: logBookAbi, functionName: "count" })) as bigint;
  log(`    rebalance tx ${rebTx}  (status ${rebRcpt.status})`);
  log(`    tracked USDC ${tuBefore} → ${tuAfter}   tracked MON ${tmBefore} → ${tmAfter}`);
  log(`    LogBook count ${logCountBefore} → ${logCountAfter}  (entry seq ${logCountAfter - 1n})`);
  const logged = parseEventLogs({ abi: logBookAbi, logs: rebRcpt.logs, eventName: "Logged" });
  if (logged[0]) {
    const a = logged[0].args as any;
    log(`    LogBook entry: priceE8=${a.priceE8} bpsBefore=${a.bpsBefore} bpsAfter=${a.bpsAfter} navBefore=${a.navBefore} navAfter=${a.navAfter}`);
  }

  // 4) In-kind withdraw by the demo user → expect pro-rata USDC + MON.
  log(`\n[4] in-kind withdraw (redeemInKind of all demo-user shares)…`);
  const myShares = (await pub.readContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "balanceOf", args: [deployer.address] })) as bigint;
  const usdcBefore = (await pub.readContract({ address: USDC, abi: usdcAbi, functionName: "balanceOf", args: [deployer.address] })) as bigint;
  const monBefore = await pub.getBalance({ address: deployer.address });
  const wTx = await dW.writeContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "redeemInKind", args: [myShares, deployer.address], chain: monadTestnet, account: deployer, gas: 300_000n });
  await wait(wTx);
  const usdcAfter = (await pub.readContract({ address: USDC, abi: usdcAbi, functionName: "balanceOf", args: [deployer.address] })) as bigint;
  const monAfter = await pub.getBalance({ address: deployer.address });
  const sharesEnd = (await pub.readContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "balanceOf", args: [deployer.address] })) as bigint;
  log(`    withdraw tx ${wTx}`);
  log(`    redeemed ${myShares} shares → USDC +${usdcAfter - usdcBefore}, MON Δ ${monAfter - monBefore} wei (net of gas)`);
  log(`    remaining shares: ${sharesEnd}`);

  // 5) Accounting sanity — vault physically holds >= tracked (solvency invariant).
  const tuEnd = (await pub.readContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "trackedUsdc" })) as bigint;
  const tmEnd = (await pub.readContract({ address: VAULT, abi: hardenedVaultAbi, functionName: "trackedMon" })) as bigint;
  const vUsdc = (await pub.readContract({ address: USDC, abi: usdcAbi, functionName: "balanceOf", args: [VAULT] })) as bigint;
  const vMon = await pub.getBalance({ address: VAULT });
  log(`\n[5] accounting: trackedUsdc=${tuEnd} (vault USDC ${vUsdc})  trackedMon=${tmEnd} (vault MON ${vMon})`);
  log(`    solvency: USDC ${vUsdc >= tuEnd ? "OK" : "FAIL"}, MON ${vMon >= tmEnd ? "OK" : "FAIL"}`);
  log("\n=== STEP 7 e2e complete ===");
}

main().catch((e) => { console.error("e2e fatal:", e instanceof Error ? e.message : e); process.exit(1); });
