import {
  encodeFunctionData,
  type Account,
  type Hash,
  type PublicClient,
  type WalletClient,
} from "viem";
import { ADDRESSES, PYTH_CONTRACT, SLIPPAGE_BPS, monadTestnet } from "./config.js";
import { pythAbi, pythReaderAbi, hardenedVaultAbi } from "./abiHardened.js";
import { vaultAbi } from "./abi.js";
import { decide, formatBps, type Decision } from "./strategy.js";
import { formatPriceE8 } from "./pyth.js";
import { getMonUsdUpdate, type MonUsdUpdate } from "./pythUpdate.js";

const ZERO = "0x0000000000000000000000000000000000000000" as const;
const NATIVE = ZERO; // SafeSwapExecutor uses address(0) for native MON

export interface Portfolio {
  monWei: bigint;
  usdc6: bigint;
  source: "HardenedVault" | "LegacyRebalanceVault";
}

export interface HardenedTickResult {
  ok: boolean;
  error?: string;
  dryRun: boolean;

  // price leg
  priceE8?: bigint;
  confBps?: bigint;
  publishTime?: number;
  updateFeeWei?: bigint;
  onChainReadPriceE8?: bigint; // from parse simulation (proves on-chain acceptance)
  pushTx?: Hash;

  // portfolio + decision
  portfolio?: Portfolio;
  bpsBefore?: bigint;
  decision?: Decision;

  // intended swap
  monToUsdc?: boolean;
  amountIn?: bigint;     // wei (MON) or 6-dec (USDC) depending on direction
  minOut?: bigint;
  routerCalldata?: `0x${string}`;
  router?: `0x${string}`;
  rebalanceTx?: Hash;
}

function isZero(a?: string): boolean {
  return !a || a.toLowerCase() === ZERO;
}

async function readPortfolio(pub: PublicClient): Promise<Portfolio> {
  if (!isZero(ADDRESSES.HardenedVault)) {
    const v = ADDRESSES.HardenedVault as `0x${string}`;
    const [mon, usdc] = await Promise.all([
      pub.readContract({ address: v, abi: hardenedVaultAbi, functionName: "trackedMon" }) as Promise<bigint>,
      pub.readContract({ address: v, abi: hardenedVaultAbi, functionName: "trackedUsdc" }) as Promise<bigint>,
    ]);
    return { monWei: mon, usdc6: usdc, source: "HardenedVault" };
  }
  // Pre-deploy dry-run: use the legacy vault's live balances as a realistic stand-in.
  const lv = ADDRESSES.RebalanceVault;
  const [mon, usdc] = await Promise.all([
    pub.readContract({ address: lv, abi: vaultAbi, functionName: "monBalance" }) as Promise<bigint>,
    pub.readContract({ address: lv, abi: vaultAbi, functionName: "usdcBalance" }) as Promise<bigint>,
  ]);
  return { monWei: mon, usdc6: usdc, source: "LegacyRebalanceVault" };
}

// Compute the swap to move toward 60/40, plus the on-chain-style minOut.
export function planSwap(p: Portfolio, priceE8: bigint): {
  monToUsdc: boolean;
  amountIn: bigint;
  minOut: bigint;
  grossOut: bigint;
} | null {
  const monVal = (p.monWei * priceE8) / 10n ** 20n; // 6 dec
  const nav = monVal + p.usdc6;
  if (nav === 0n) return null;
  const target = (nav * 6000n) / 10_000n;
  const band = (nav * 500n) / 10_000n;
  const bonus = (x: bigint) => (x * (10_000n - SLIPPAGE_BPS)) / 10_000n;

  if (monVal > target && monVal - target > band) {
    // trim MON -> USDC
    const deltaUsdc = monVal - target;
    let amountIn = (deltaUsdc * 10n ** 20n) / priceE8; // wei MON to sell
    if (amountIn > p.monWei) amountIn = p.monWei;
    const grossOut = (amountIn * priceE8) / 10n ** 20n; // USDC (6 dec)
    return { monToUsdc: true, amountIn, minOut: bonus(grossOut), grossOut };
  }
  if (target > monVal && target - monVal > band) {
    // buy MON with USDC
    let amountIn = target - monVal; // USDC (6 dec)
    if (amountIn > p.usdc6) amountIn = p.usdc6;
    const grossOut = (amountIn * 10n ** 20n) / priceE8; // wei MON
    return { monToUsdc: false, amountIn, minOut: bonus(grossOut), grossOut };
  }
  return null;
}

function buildRouterCalldata(monToUsdc: boolean, grossOut: bigint, amountIn: bigint): `0x${string}` {
  const usdc = ADDRESSES.MockUSDC;
  // MockSwapRouter.swap(tokenIn, tokenOut, pullIn, pushOut). pushOut is the route's
  // quoted output; in production it comes from the DEX/aggregator route. For the
  // testnet mock router the agent quotes it to the fair Pyth gross (>= minOut).
  if (monToUsdc) {
    return encodeFunctionData({
      abi: pythAbi, functionName: "swap",
      args: [NATIVE, usdc, 0n, grossOut],
    });
  }
  return encodeFunctionData({
    abi: pythAbi, functionName: "swap",
    args: [usdc, NATIVE, amountIn, grossOut],
  });
}

export interface HardenedTickDeps {
  publicClient: PublicClient;
  agentWallet?: WalletClient & { account: Account };
}

/**
 * One hardened-vault tick. In dryRun mode it performs ONLY read-only calls:
 *   1. fetch Hermes update data + parsed price (stable network)
 *   2. read the on-chain Pyth update fee
 *   3. (optional) simulate parsePriceFeedUpdates → proves the contract accepts the data
 *      and yields the exact priceE8 readPriceE8() would return
 *   4. read portfolio, decide 60/40 action, compute amountIn + minOut + router calldata
 * No state-changing tx is sent. Live mode (dryRun=false) additionally pushes the
 * price via PythPriceReader.updatePrice and calls HardenedVault.rebalance.
 */
export async function hardenedTick(
  deps: HardenedTickDeps,
  opts: { dryRun: boolean; verifyOnChainRead?: boolean } = { dryRun: true },
): Promise<HardenedTickResult> {
  const { publicClient: pub, agentWallet } = deps;
  const dryRun = opts.dryRun;
  try {
    // 1) Hermes update data + parsed price.
    const upd: MonUsdUpdate = await getMonUsdUpdate();

    // 2) On-chain update fee (read-only).
    const updateFeeWei = (await pub.readContract({
      address: PYTH_CONTRACT, abi: pythAbi, functionName: "getUpdateFee", args: [upd.updateData],
    })) as bigint;

    // 3) Optionally prove on-chain acceptance + get the exact on-chain priceE8.
    let onChainReadPriceE8: bigint | undefined;
    if (opts.verifyOnChainRead) {
      const sim = await pub.simulateContract({
        address: PYTH_CONTRACT, abi: pythAbi, functionName: "parsePriceFeedUpdates",
        args: [upd.updateData, [ADDRESSES.monUsdFeedId as `0x${string}`], 0n, 4294967295n],
        value: updateFeeWei,
        account: ADDRESSES.agent,
      });
      const feed = (sim.result as readonly any[])[0];
      const raw = BigInt(feed.price.price);
      const expo = Number(feed.price.expo);
      const shift = expo + 8;
      onChainReadPriceE8 = shift === 0 ? raw : shift > 0 ? raw * 10n ** BigInt(shift) : raw / 10n ** BigInt(-shift);
    }

    // 3b) Live: push the fresh price on-chain via the reader.
    let pushTx: Hash | undefined;
    if (!dryRun && agentWallet && !isZero(ADDRESSES.PythPriceReader)) {
      pushTx = await agentWallet.writeContract({
        address: ADDRESSES.PythPriceReader as `0x${string}`, abi: pythReaderAbi,
        functionName: "updatePrice", args: [upd.updateData], value: updateFeeWei,
        chain: monadTestnet, account: agentWallet.account, type: "legacy", gas: 400_000n,
      });
      await pub.waitForTransactionReceipt({ hash: pushTx });
    }

    // 4) Fresh on-chain price to act on. Dry-run: Hermes parsed price (== what the
    //    contract returns post-push). Live: read straight from the reader.
    let priceE8 = upd.priceE8;
    if (!dryRun && !isZero(ADDRESSES.PythPriceReader)) {
      priceE8 = (await pub.readContract({
        address: ADDRESSES.PythPriceReader as `0x${string}`, abi: pythReaderAbi, functionName: "readPriceE8",
      })) as bigint;
    }

    // 5) Portfolio + decision.
    const portfolio = await readPortfolio(pub);
    const monVal = (portfolio.monWei * priceE8) / 10n ** 20n;
    const nav = monVal + portfolio.usdc6;
    const bpsBefore = nav === 0n ? 0n : (monVal * 10_000n) / nav;
    const decision = decide(bpsBefore);

    const result: HardenedTickResult = {
      ok: true, dryRun, priceE8, confBps: upd.confBps, publishTime: upd.publishTime,
      updateFeeWei, onChainReadPriceE8, pushTx, portfolio, bpsBefore, decision,
    };

    // 6) Plan / execute the swap.
    if (decision.action !== "hold") {
      const plan = planSwap(portfolio, priceE8);
      if (plan) {
        const router = (ADDRESSES.swapRouter ?? ZERO) as `0x${string}`;
        const calldata = buildRouterCalldata(plan.monToUsdc, plan.grossOut, plan.amountIn);
        result.monToUsdc = plan.monToUsdc;
        result.amountIn = plan.amountIn;
        result.minOut = plan.minOut;
        result.router = router;
        result.routerCalldata = calldata;

        if (!dryRun && agentWallet && !isZero(ADDRESSES.HardenedVault) && !isZero(router)) {
          const tx = await agentWallet.writeContract({
            address: ADDRESSES.HardenedVault as `0x${string}`, abi: hardenedVaultAbi,
            functionName: "rebalance", args: [router, calldata, plan.monToUsdc, plan.amountIn],
            chain: monadTestnet, account: agentWallet.account, type: "legacy", gas: 800_000n,
          });
          await pub.waitForTransactionReceipt({ hash: tx });
          result.rebalanceTx = tx;
        }
      }
    }

    return result;
  } catch (e: unknown) {
    return { ok: false, dryRun, error: e instanceof Error ? e.message : String(e) };
  }
}

export function formatHardenedTick(r: HardenedTickResult): string {
  if (!r.ok) return `tick error: ${r.error}`;
  const L: string[] = [];
  const price = r.priceE8 !== undefined ? formatPriceE8(r.priceE8) : "?";
  L.push(`${r.dryRun ? "[DRY-RUN] " : ""}tick`);
  L.push(`  price (Hermes→E8): ${price}   conf: ${r.confBps ?? "?"} bps   publishTime: ${r.publishTime ?? "?"}`);
  if (r.onChainReadPriceE8 !== undefined)
    L.push(`  on-chain read (parse sim): ${formatPriceE8(r.onChainReadPriceE8)}  ← contract accepts the VAA`);
  L.push(`  Pyth update fee: ${r.updateFeeWei ?? "?"} wei`);
  if (r.portfolio)
    L.push(`  portfolio [${r.portfolio.source}]: ${r.portfolio.monWei} wei MON + ${r.portfolio.usdc6} (6dp) USDC`);
  L.push(`  MON share: ${r.bpsBefore !== undefined ? formatBps(r.bpsBefore) : "?"}   action: ${r.decision?.action}  (${r.decision?.reason})`);
  if (r.amountIn !== undefined) {
    L.push(`  intended swap: ${r.monToUsdc ? "MON→USDC" : "USDC→MON"}  amountIn=${r.amountIn}  minOut=${r.minOut}  (slippage cap ${SLIPPAGE_BPS} bps)`);
    L.push(`  router=${r.router}  calldata=${r.routerCalldata?.slice(0, 26)}…`);
  }
  if (r.pushTx) L.push(`  pushTx=${r.pushTx}`);
  if (r.rebalanceTx) L.push(`  rebalanceTx=${r.rebalanceTx}`);
  return L.join("\n");
}
