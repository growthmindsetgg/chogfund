"use client";

import { useMemo, useState } from "react";
import { useAccount, usePublicClient } from "wagmi";
import { toast } from "sonner";
import addresses from "@addresses";
import { allocatorAbi, usdcAbi } from "@/abi";
import { Card, CardContent, CardHeader } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useAllocatorSnapshot } from "@/hooks/useAllocatorSnapshot";
import { useSendTransactionSync } from "@/hooks/useSendTransactionSync";
import { cn, formatMON, formatUSDC, parseUSDCInput } from "@/lib/utils";
import { classifyTxError } from "@/lib/tx";

const VAULT = addresses.AllocatorVault as `0x${string}`;
const USDC = addresses.MockUSDC as `0x${string}`;

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
  const amount = useMemo(() => parseUSDCInput(str), [str]);
  const allowance = snap?.userUsdcAllowance ?? 0n;
  const balance = snap?.userUsdcBalance ?? 0n;

  const needsApprove = amount > 0n && allowance < amount;
  const overBalance = amount > balance;

  const onMax = () => setStr(formatUSDC(balance, 2));

  const approve = async () => {
    if (!publicClient || amount === 0n) return;
    try {
      await publicClient.simulateContract({
        address: USDC, abi: usdcAbi, functionName: "approve", args: [VAULT, amount], account: address,
      });
    } catch (e) { toast.error(classifyTxError(e).message); return; }
    try {
      const receipt = await tx.send({ address: USDC, abi: usdcAbi, functionName: "approve", args: [VAULT, amount] });
      if (receipt.status !== "success") { toast.error("Approve reverted on-chain."); return; }
      await refetch();
      toast.success("USDC approved. You can deposit now.");
    } catch (e) { toast.error(classifyTxError(e).message); }
  };

  const deposit = async () => {
    if (!publicClient || amount === 0n) { toast.error("Enter an amount"); return; }
    // Pre-flight simulate: agent wallet hits AgentBlocked here, never reaches signing.
    try {
      await publicClient.simulateContract({
        address: VAULT, abi: allocatorAbi, functionName: "deposit", args: [amount, address], account: address,
      });
    } catch (e) { toast.error(classifyTxError(e).message); return; }
    try {
      const receipt = await tx.send({ address: VAULT, abi: allocatorAbi, functionName: "deposit", args: [amount, address] });
      if (receipt.status !== "success") { toast.error("Deposit reverted on-chain."); return; }
      setStr("");
      await refetch();
      toast.success("Deposit confirmed.");
    } catch (e) { toast.error(classifyTxError(e).message); }
  };

  const disabled = tx.loading || amount === 0n || overBalance;
  const label = tx.loading ? "Confirming…" : needsApprove ? "Approve USDC" : "Deposit USDC";
  const onClick = needsApprove ? approve : deposit;

  return (
    <div className="space-y-4">
      <p className="text-sm text-[var(--text-muted)]">
        Deposit USDC. The agent allocates it across the 60/40 MON/USDC mix, the LP leg and parked yield — and rebalances
        automatically. Withdraw your share any time.
      </p>
      <AmountField label="USDC" value={str} onChange={setStr} balanceLabel={`${formatUSDC(balance, 2)} USDC`} onMax={onMax} />
      {overBalance && <p className="text-xs text-[var(--rose)]">Amount exceeds your USDC balance.</p>}

      <Button onClick={onClick} disabled={disabled} size="lg" className="w-full">{label}</Button>

      {needsApprove && !tx.loading && (
        <p className="text-center text-xs text-[var(--text-muted)]">Two steps: approve USDC once, then deposit.</p>
      )}
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
        No position yet. Deposit USDC to get started.
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
