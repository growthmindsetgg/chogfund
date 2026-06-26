"use client";

import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { useAllocatorSnapshot } from "@/hooks/useAllocatorSnapshot";
import { formatUSDC } from "@/lib/utils";

interface Leg {
  key: string;
  label: string;
  sub: string;
  value: bigint;
  color: string;   // bar fill
  dot: string;     // legend dot
}

function pctOf(v: bigint, total: bigint): number {
  if (total <= 0n) return 0;
  return Number((v * 10000n) / total) / 100;
}

export function AllocationCard() {
  const { data: snap } = useAllocatorSnapshot();
  const nav = snap?.nav ?? 0n;

  const legs: Leg[] = [
    { key: "mon",    label: "MON",    sub: "base, native",          value: snap?.baseMonValue ?? 0n, color: "var(--purple)", dot: "var(--purple)" },
    { key: "usdc",   label: "USDC",   sub: "base, idle",            value: snap?.baseUsdc ?? 0n,     color: "var(--berry)",  dot: "var(--berry)" },
    { key: "lp",     label: "LP",     sub: "MON/USDC concentrated", value: snap?.lpValue ?? 0n,      color: "var(--blue)",   dot: "var(--blue)" },
    { key: "parked", label: "Parked", sub: "ERC4626 yield",         value: snap?.parkedValue ?? 0n,  color: "var(--green)",  dot: "var(--green)" },
  ];

  const hasNav = nav > 0n;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Allocation</CardTitle>
        <CardDescription>Where NAV sits right now. Each leg is valued on-chain and sums to NAV.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        {/* Stacked bar */}
        <div className="flex h-3.5 w-full overflow-hidden rounded-full bg-[var(--purple-soft)]">
          {hasNav && legs.map((l) => {
            const p = pctOf(l.value, nav);
            if (p <= 0) return null;
            return (
              <div
                key={l.key}
                style={{ width: `${p}%`, background: l.color }}
                className="h-full"
                title={`${l.label}: ${p.toFixed(1)}%`}
              />
            );
          })}
        </div>

        {/* Legend */}
        <div className="grid grid-cols-2 gap-x-6 gap-y-3">
          {legs.map((l) => (
            <div key={l.key} className="flex items-start justify-between gap-3">
              <div className="flex items-start gap-2 min-w-0">
                <span className="mt-1 size-2.5 shrink-0 rounded-full" style={{ background: l.dot }} aria-hidden />
                <div className="min-w-0">
                  <div className="text-sm font-semibold text-[var(--text)]">{l.label}</div>
                  <div className="text-xs text-[var(--text-muted)] truncate">{l.sub}</div>
                </div>
              </div>
              <div className="text-right shrink-0">
                <div className="font-mono text-sm font-semibold tabular-nums text-[var(--text)]">
                  ${formatUSDC(l.value, 2)}
                </div>
                <div className="text-xs text-[var(--text-muted)] tabular-nums">
                  {hasNav ? `${pctOf(l.value, nav).toFixed(1)}%` : "—"}
                </div>
              </div>
            </div>
          ))}
        </div>
      </CardContent>
    </Card>
  );
}
