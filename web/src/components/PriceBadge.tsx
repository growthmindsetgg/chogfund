"use client";

import { useAllocatorSnapshot } from "@/hooks/useAllocatorSnapshot";
import { usePythLive } from "@/hooks/usePythLive";
import { formatPriceE8 } from "@/lib/utils";

// PriceBadge — header MON/USD pill (P8, P4-wired).
//
// Displayed value: the on-chain pushed price the vault actually uses,
// PythPriceReader.readPriceE8() (surfaced via useAllocatorSnapshot). Drives NAV.
// Independent comparison: live Pyth STABLE Hermes (usePythLive) — the SAME feed
// the contract reads. If they diverge by >2%, an amber chip surfaces so a stale
// pushed price is NEVER silently presented as truth.
export function PriceBadge() {
  const { data: snap, isLoading, isFetching } = useAllocatorSnapshot();
  const { data: pythE8 } = usePythLive();

  const onChain = snap?.priceE8 ?? 0n;
  const ready = onChain > 0n;
  const label = ready ? formatPriceE8(onChain) : (isLoading || isFetching ? "…" : "—");

  let driftBps = 0n;
  if (pythE8 && pythE8 > 0n && onChain > 0n) {
    const diff = onChain > pythE8 ? onChain - pythE8 : pythE8 - onChain;
    driftBps = (diff * 10_000n) / pythE8;
  }
  const diverged = driftBps > 200n; // >2%

  return (
    <div className="flex items-center gap-1.5">
      <span
        className="font-mono text-xs px-2.5 py-1 rounded-lg bg-[var(--purple-soft)] text-[var(--purple-strong)] tabular-nums"
        title={`MON/USD — displayed = on-chain pushed price (PythPriceReader.readPriceE8, drives NAV). Live Pyth (stable) = ${pythE8 ? formatPriceE8(pythE8) : "…"}.`}
      >
        MON {label}
      </span>
      {diverged && (
        <span
          className="font-medium text-[10px] px-2 py-0.5 rounded-md bg-amber-100 text-amber-800 border border-amber-300"
          title={`Live Pyth (stable): ${pythE8 ? formatPriceE8(pythE8) : "—"} — on-chain pushed price drifted ${(Number(driftBps) / 100).toFixed(1)}%. Start the pyth-pusher to refresh.`}
        >
          oracle syncing
        </span>
      )}
    </div>
  );
}
