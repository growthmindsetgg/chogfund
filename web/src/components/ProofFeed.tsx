"use client";

import { ExternalLink } from "lucide-react";
import addresses from "@addresses";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { useP4Feed } from "@/hooks/useP4Feed";
import { EXPLORER_BASE } from "@/wagmi";
import { formatBps, formatPriceE8, formatUSDC } from "@/lib/utils";

// On-chain proof: every row is a LogBookP4 entry the vault wrote itself
// (NAV/bps before→after). The agent cannot forge these — only the vault can
// append. Rows always render from entries(i) reads; the per-tx link appears
// when the Logged event is inside the live ≤100-block getLogs window.
export function ProofFeed() {
  const { data: feed } = useP4Feed();
  const entries = feed?.entries ?? [];
  const logUrl = `${EXPLORER_BASE}/address/${addresses.LogBookP4}`;

  return (
    <Card>
      <CardHeader className="flex flex-row items-start justify-between gap-4">
        <div>
          <CardTitle>On-chain proof</CardTitle>
          <CardDescription className="mt-1">
            Written on-chain by the vault on every action. {feed ? `${feed.logBookCount} entries.` : ""}
          </CardDescription>
        </div>
        <a
          href={logUrl}
          target="_blank"
          rel="noreferrer"
          className="mt-1 inline-flex items-center gap-1 text-xs font-semibold text-[var(--purple-strong)] hover:underline"
        >
          LogBook <ExternalLink className="size-3" />
        </a>
      </CardHeader>
      <CardContent>
        {entries.length === 0 ? (
          <div className="py-8 text-center text-sm text-[var(--text-muted)]">No entries yet.</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-xs font-mono tabular-nums">
              <thead>
                <tr className="text-left text-[var(--text-muted)]">
                  <th className="py-2 pr-3 font-medium">#</th>
                  <th className="py-2 pr-3 font-medium">MON/USD</th>
                  <th className="py-2 pr-3 font-medium">MON % (before→after)</th>
                  <th className="py-2 pr-3 font-medium">NAV $ (before→after)</th>
                  <th className="py-2 pr-3 font-medium">time</th>
                  <th className="py-2 pr-3 font-medium">tx</th>
                </tr>
              </thead>
              <tbody>
                {entries.slice(0, 20).map((e) => (
                  <tr key={e.seq} className="border-t border-[var(--border)]">
                    <td className="py-2 pr-3 text-[var(--text-muted)]">{e.seq}</td>
                    <td className="py-2 pr-3">{formatPriceE8(e.priceE8)}</td>
                    <td className="py-2 pr-3">{formatBps(e.bpsBefore)} → {formatBps(e.bpsAfter)}</td>
                    <td className="py-2 pr-3">${formatUSDC(e.navBefore, 2)} → ${formatUSDC(e.navAfter, 2)}</td>
                    <td className="py-2 pr-3 text-[var(--text-muted)]">{new Date(Number(e.ts) * 1000).toLocaleTimeString()}</td>
                    <td className="py-2 pr-3">
                      <a
                        href={`${EXPLORER_BASE}/${e.txHash ? `tx/${e.txHash}` : `address/${addresses.LogBookP4}`}`}
                        target="_blank"
                        rel="noreferrer"
                        className="inline-flex items-center gap-1 text-[var(--purple-strong)] hover:underline"
                      >
                        {e.txHash ? "view" : "log"} <ExternalLink className="size-3" />
                      </a>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
