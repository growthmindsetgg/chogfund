"use client";

import { useMemo, useState } from "react";
import { useAccount, usePublicClient } from "wagmi";
import { toast } from "sonner";
import addresses from "@addresses";
import { allocatorAbi, pythReaderAbi } from "@/abi";
import { Card, CardContent, CardHeader } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useAllocatorSnapshot } from "@/hooks/useAllocatorSnapshot";
import { useSendTransactionSync } from "@/hooks/useSendTransactionSync";
import { fetchMonUsdUpdateData } from "@/lib/pythUpdate";
import { cn, formatMON, formatUSDC, parseMONInput } from "@/lib/utils";
import { classifyTxError } from "@/lib/tx";

const VAULT = addresses.AllocatorVault as `0x${string}`;
const READER = addresses.PythPriceReader as `0x${string}`;
const GAS_PAD_WEI = 10_000_000_000_000_000n; // 0.01 MON kept back for gas + oracle fee

type Tab = "deposit" | "withdraw";

export function VaultPanel() {
  const { address } = useAccount();
  const publicClient = usePublicClient();
  const { data: snap, refetch } = useAllocatorSnapshot();
  const tx = useSendTransactionSync();
  const [tab, setTab] = useState<Tab>("deposit");

  if (!address) {
    return (
      <Card>
        <CardContent className="py-12 text-center text-[var(--text-muted)]">
          Connect a wallet to deposit or withdraw.
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader className="pb-4">
        <div className="grid grid-cols-2 gap-1 rounded-2xl bg-[var(--purple-soft)] p-1 text-sm">
          {(["deposit", "withdraw"] as Tab[]).map((t) => (
            <button
              key={t}
              type="button"
              onClick={() => setTab(t)}
              className={cn(
                "rounded-xl py-2 font-semibold capitalize transition-colors",
                tab === t ? "bg-white text-[var(--purple-strong)] shadow-sm" : "text-[var(--text-muted)] hover:text-[var(--purple-strong)]",
              )}
            >
              {t}
            </button>
          ))}
        </div>
      </CardHeader>
      <CardContent>
        {tab === "deposit"
          ? <DepositForm snap={snap} tx={tx} refetch={refetch} address={address} publicClient={publicClient} />
          : <WithdrawForm snap={snap} tx={tx} refetch={refetch} address={address} publicClient={publicClient} />}
      </CardContent>
    </Card>
  );
}

/* eslint-disable @typescript-eslint/no-explicit-any */
type FormProps = {
  snap: ReturnType<typeof useAllocatorSnapshot>["data"];
  tx: ReturnType<typeof useSendTransactionSync>;
  refetch: () => unknown;
  address: `0x${string}`;
  publicClient: any;
};

function DepositForm({ snap, tx, refetch, address, publicClient }: FormProps) {
  const [str, setStr] = useState("");
  const [preparing, setPreparing] = useState(false);
  const monIn = useMemo(() => parseMONInput(str), [str]);
  const balance = snap?.userMonBalance ?? 0n;

  // need room for the deposit + gas + the tiny oracle fee
  const overBalance = monIn > 0n && monIn + GAS_PAD_WEI > balance;
  const onMax = () => setStr(formatMON(balance > GAS_PAD_WEI ? balance - GAS_PAD_WEI : 0n, 4));

  const busy = preparing || tx.loading;

  const deposit = async () => {
    if (!publicClient) return;
    if (monIn === 0n) { toast.error("Enter a MON amount"); return; }
    if (overBalance) { toast.error("Leave a little MON for gas"); return; }

    setPreparing(true);
    let updateData: `0x${string}`[];
    let fee: bigint;
    try {
      // fresh stable-Hermes VAA + its on-chain update fee (update-then-mint)
      updateData = await fetchMonUsdUpdateData();
      fee = (await publicClient.readContract({
        address: READER, abi: pythReaderAbi, functionName: "getUpdateFee", args: [updateData],
      })) as bigint;
    } catch {
      setPreparing(false);
      toast.error("Couldn't fetch the live price update. Try again.");
      return;
    }

    const value = monIn + fee; // depositMON splits: fee → Pyth, remainder → your deposit

    // Pre-flight simulate: agent wallet hits AgentBlocked here, stale price → price-unset, etc.
    try {
      await publicClient.simulateContract({
        address: VAULT, abi: allocatorAbi, functionName: "depositMON",
        args: [updateData, address], value, account: address,
      });
    } catch (e) {
      setPreparing(false);
      toast.error(classifyTxError(e).message);
      return;
    }
    setPreparing(false);

    try {
      const receipt = await tx.send({
        address: VAULT, abi: allocatorAbi, functionName: "depositMON",
        args: [updateData, address], value,
      });
      if (receipt.status !== "success") { toast.error("Deposit reverted on-chain."); return; }
      setStr("");
      await refetch();
      toast.success("MON deposited.");
    } catch (e) {
      toast.error(classifyTxError(e).message);
    }
  };

  return (
    <div className="space-y-4">
      <p className="text-sm text-[var(--text-muted)]">
        Deposit MON. The agent values it at the live Pyth price and allocates across the 60/40 MON/USDC mix,
        the LP leg and parked yield — rebalancing automatically. Withdraw your share any time.
      </p>
      <AmountField label="MON" value={str} onChange={setStr} balanceLabel={`${formatMON(balance, 4)} MON`} onMax={onMax} />
      {overBalance && <p className="text-xs text-[var(--rose)]">Leave a little MON for gas + the oracle fee.</p>}

      <Button onClick={deposit} disabled={busy || monIn === 0n || overBalance} size="lg" className="w-full">
        {preparing ? "Fetching live price…" : tx.loading ? "Confirming…" : "Deposit MON"}
      </Button>

      <p className="text-center text-xs text-[var(--text-muted)]">
        Your deposit includes a tiny on-chain oracle fee (a fresh Pyth price update, ~a few wei) so your MON is
        valued at the live price the moment you deposit.
      </p>
    </div>
  );
}

function WithdrawForm({ snap, tx, refetch, address, publicClient }: FormProps) {
  const [percent, setPercent] = useState(100);
  const userShares = snap?.userShares ?? 0n;
  const totalShares = snap?.totalShares ?? 0n;

  const withdrawShares = useMemo(
    () => (userShares * BigInt(percent)) / 100n,
    [userShares, percent],
  );

  // Estimated value + in-kind split (pro-rata of tracked base + legs).
  const est = useMemo(() => {
    if (!snap || totalShares === 0n || withdrawShares === 0n) return { usd: 0n, mon: 0n, usdc: 0n };
    const usd  = (snap.userValueUsdc * BigInt(percent)) / 100n;
    const mon  = (snap.trackedMon  * withdrawShares) / totalShares;
    const usdc = (snap.trackedUsdc * withdrawShares) / totalShares;
    return { usd, mon, usdc };
  }, [snap, totalShares, withdrawShares, percent]);

  const onWithdraw = async () => {
    if (!publicClient || withdrawShares === 0n) { toast.error("Choose an amount"); return; }
    try {
      await publicClient.simulateContract({
        address: VAULT, abi: allocatorAbi, functionName: "redeemInKind", args: [withdrawShares, address], account: address,
      });
    } catch (e) { toast.error(classifyTxError(e).message); return; }
    try {
      const receipt = await tx.send({ address: VAULT, abi: allocatorAbi, functionName: "redeemInKind", args: [withdrawShares, address] });
      if (receipt.status !== "success") { toast.error("Withdraw reverted on-chain."); return; }
      await refetch();
      toast.success(percent === 100 ? "Withdrew everything." : "Withdraw confirmed.");
    } catch (e) { toast.error(classifyTxError(e).message); }
  };

  if (userShares === 0n) {
    return (
      <div className="py-10 text-center text-sm text-[var(--text-muted)]">
        No position yet. Deposit MON to get started.
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <p className="text-sm text-[var(--text-muted)]">
        Redeem in-kind: you receive your pro-rata MON + USDC directly. No oracle needed — works even while paused.
      </p>
      <input
        type="range" min={0} max={100} value={percent}
        onChange={(e) => setPercent(Number(e.target.value))}
        className="w-full accent-[var(--purple)]"
      />
      <div className="text-center text-2xl font-bold text-[var(--purple-strong)]">{percent}%</div>
      <div className="flex gap-2">
        {[25, 50, 75, 100].map((p) => (
          <Button key={p} variant="secondary" size="sm" onClick={() => setPercent(p)} className="flex-1">
            {p === 100 ? "MAX" : `${p}%`}
          </Button>
        ))}
      </div>

      <div className="rounded-xl bg-[var(--purple-soft)] p-3 space-y-1">
        <div className="text-xs uppercase tracking-wide text-[var(--text-muted)]">You&apos;ll receive</div>
        <div className="text-xl font-extrabold text-[var(--purple-strong)] tabular-nums">≈ ${formatUSDC(est.usd, 2)}</div>
        <div className="font-mono text-xs text-[var(--text-muted)] tabular-nums">
          {formatMON(est.mon, 4)} MON + {formatUSDC(est.usdc, 2)} USDC
        </div>
      </div>

      <Button onClick={onWithdraw} disabled={tx.loading || withdrawShares === 0n} size="lg" className="w-full">
        {tx.loading ? "Confirming…" : "Withdraw"}
      </Button>
    </div>
  );
}

function AmountField({
  label, value, onChange, balanceLabel, onMax,
}: {
  label: string; value: string; onChange: (v: string) => void; balanceLabel: string; onMax: () => void;
}) {
  return (
    <div className="space-y-1.5">
      <div className="flex items-center justify-between text-sm">
        <span className="font-semibold text-[var(--text)]">{label}</span>
        <span className="text-[var(--text-muted)]">Balance: {balanceLabel}</span>
      </div>
      <div className="relative">
        <Input
          inputMode="decimal" placeholder="0.00" value={value}
          onChange={(e) => onChange(e.target.value.replace(/[^0-9.]/g, ""))}
          className="pr-16"
        />
        <button
          type="button" onClick={onMax}
          className="absolute right-3 top-1/2 -translate-y-1/2 text-xs font-semibold text-[var(--purple-strong)] hover:underline"
        >
          MAX
        </button>
      </div>
    </div>
  );
}
