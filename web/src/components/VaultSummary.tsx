"use client";

import { useAccount } from "wagmi";
import { Card, CardContent } from "@/components/ui/card";
import { useAllocatorSnapshot } from "@/hooks/useAllocatorSnapshot";
import { formatUSDC } from "@/lib/utils";

function pctOfVault(userShares: bigint, totalShares: bigint): string {
  if (totalShares <= 0n || userShares <= 0n) return "—";
  const bps = (userShares * 10_000n) / totalShares;
  return `${(Number(bps) / 100).toFixed(2)}% of vault`;
}

export function VaultSummary() {
  const { address } = useAccount();
  const { data: snap } = useAllocatorSnapshot();

  const nav = snap?.nav ?? 0n;
  const sharePrice = snap?.sharePriceUsdc ?? 0n;
  const userValue = snap?.userValueUsdc ?? 0n;

  return (
    <div className="grid gap-4 sm:grid-cols-3">
      <Stat
        primary
        label="Net asset value"
        value={`$${formatUSDC(nav, 2)}`}
        sub="all legs, valued on-chain"
      />
      <Stat
        label="Your position"
        value={address ? `$${formatUSDC(userValue, 2)}` : "—"}
        sub={address ? pctOfVault(snap?.userShares ?? 0n, snap?.totalShares ?? 0n) : "connect wallet"}
      />
      <Stat
        label="Share price"
        value={`$${formatUSDC(sharePrice, 4)}`}
        sub="per cvCHOG share"
      />
    </div>
  );
}

function Stat({ label, value, sub, primary }: { label: string; value: string; sub: string; primary?: boolean }) {
  return (
    <Card className={primary ? "bg-[var(--blue)] text-white border-transparent" : ""}>
      <CardContent className="py-5">
        <div className={`text-xs uppercase tracking-wide ${primary ? "text-white/70" : "text-[var(--text-muted)]"}`}>
          {label}
        </div>
        <div className={`mt-1 text-3xl font-black tabular-nums ${primary ? "text-white" : "text-[var(--blue)]"}`}>
          {value}
        </div>
        <div className={`mt-0.5 text-xs ${primary ? "text-white/60" : "text-[var(--text-muted)]"}`}>{sub}</div>
      </CardContent>
    </Card>
  );
}
