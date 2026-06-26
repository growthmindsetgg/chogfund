"use client";

import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { useAllocatorSnapshot } from "@/hooks/useAllocatorSnapshot";
import { useP4Feed } from "@/hooks/useP4Feed";
import { formatPriceE8, shortAddress } from "@/lib/utils";
import { EXPLORER_BASE } from "@/wagmi";

const KIND_LABEL: Record<string, string> = {
  alloc:     "Allocated / shifted",
  trim:      "Trimmed MON → USDC",
  add:       "Added MON ← USDC",
  emergency: "Emergency exit to base",
  hold:      "Holding — inside band",
};

export function AgentStatusCard() {
  const { data: snap } = useAllocatorSnapshot();
  const { data: feed } = useP4Feed();

  const paused = snap?.paused ?? false;
  const last = feed?.entries[0];

  return (
    <Card>
      <CardHeader className="flex flex-row items-start justify-between gap-4">
        <div>
          <CardTitle>Agent</CardTitle>
          <CardDescription className="mt-1">Autonomous · non-custodial · can only allocate &amp; rebalance.</CardDescription>
        </div>
        <span
          className={`mt-1 inline-flex items-center gap-2 rounded-full px-2.5 py-1 text-xs font-semibold ${
            paused ? "bg-[var(--berry)]/10 text-[var(--berry)]" : "bg-[var(--green)]/12 text-[var(--green)]"
          }`}
        >
          <span className={`pulse-dot ${paused ? "muted" : ""}`} aria-hidden />
          {paused ? "Paused" : "Active"}
        </span>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="grid grid-cols-2 gap-4">
          <Field label="MON / USD" value={snap ? formatPriceE8(snap.priceE8) : "—"} mono />
          <Field
            label="Agent wallet"
            value={snap?.agent ? shortAddress(snap.agent) : "—"}
            mono
            href={snap?.agent ? `${EXPLORER_BASE}/address/${snap.agent}` : undefined}
          />
        </div>
        <div className="rounded-xl bg-[var(--purple-soft)] px-4 py-3">
          <div className="text-xs uppercase tracking-wide text-[var(--text-muted)]">Last action</div>
          {last ? (
            <div className="mt-1">
              <div className="text-sm font-semibold text-[var(--purple-strong)]">
                {KIND_LABEL[last.kind] ?? "Rebalance"}
              </div>
              <div className="text-xs text-[var(--text-muted)] tabular-nums">
                {formatPriceE8(last.priceE8)} · {new Date(Number(last.ts) * 1000).toLocaleString()}
              </div>
            </div>
          ) : (
            <div className="mt-1 text-sm text-[var(--text-muted)]">Waiting for the first action…</div>
          )}
        </div>
      </CardContent>
    </Card>
  );
}

function Field({ label, value, mono, href }: { label: string; value: string; mono?: boolean; href?: string }) {
  const body = (
    <div className={`mt-1 text-base font-bold ${mono ? "font-mono" : ""} ${href ? "text-[var(--purple-strong)] hover:underline" : "text-[var(--text)]"}`}>
      {value}
    </div>
  );
  return (
    <div>
      <div className="text-xs uppercase tracking-wide text-[var(--text-muted)]">{label}</div>
      {href ? <a href={href} target="_blank" rel="noreferrer">{body}</a> : body}
    </div>
  );
}
