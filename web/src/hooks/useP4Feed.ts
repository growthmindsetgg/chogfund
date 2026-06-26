"use client";

import { useEffect, useState } from "react";
import { usePublicClient } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { parseAbiItem, type AbiEvent } from "viem";
import addresses from "@addresses";
import { logBookAbi } from "@/abi";

// P8 STEP 1 — LogBookP4 proof feed.
//
// RPC discipline (carried over from P3, unchanged):
//   * PRIMARY: LogBook.count() + entries(i) reads. These ALWAYS work and are
//     the canonical on-chain proof (the vault itself writes each row — the
//     agent cannot forge NAV/bps). Powers the proof table + activity log.
//   * SECONDARY: getLogs over a tight ≤100-block tail for tx-hash enrichment
//     (all Monad testnet RPCs cap eth_getLogs at 100 blocks). If it throws we
//     silently fall back to entries-only (older rows just lack a per-tx link).

const ZERO = "0x0000000000000000000000000000000000000000" as const;
const LIVE_TAIL_BLOCKS = 100n;

export type ActionKind = "alloc" | "trim" | "add" | "emergency" | "hold";

export interface P4LogEntry {
  seq: number;
  priceE8: bigint;
  bpsBefore: bigint;
  bpsAfter: bigint;
  navBefore: bigint;
  navAfter: bigint;
  ts: bigint;
  blockNumber?: bigint;
  txHash?: `0x${string}`;
  kind: ActionKind;
}

export interface P4Feed {
  logBookCount: number;
  entries: P4LogEntry[];      // newest first; ALWAYS populated when count > 0
  getLogsAvailable: boolean;  // false → recent tx-hash enrichment may be missing
}

function useVisible(): boolean {
  const [v, setV] = useState(typeof document === "undefined" ? true : !document.hidden);
  useEffect(() => {
    if (typeof document === "undefined") return;
    const onVis = () => setV(!document.hidden);
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, []);
  return v;
}

function classify(e: { bpsBefore: bigint; bpsAfter: bigint; navBefore: bigint; navAfter: bigint }): ActionKind {
  // EmergencyExit logs bps 0→0 with nav unchanged (see AllocatorVault).
  if (e.bpsBefore === 0n && e.bpsAfter === 0n && e.navBefore === e.navAfter) return "emergency";
  // Allocation/park/shift conserve the 60/40 mix → bps barely moves.
  if (e.bpsBefore > 6500n) return "trim";
  if (e.bpsBefore < 5500n) return "add";
  if (e.bpsAfter !== e.bpsBefore) return "alloc";
  return "hold";
}

export function useP4Feed() {
  const publicClient = usePublicClient();
  const visible = useVisible();

  const logAddr = addresses.LogBookP4 as `0x${string}`;
  const deployed = logAddr.toLowerCase() !== ZERO;

  return useQuery<P4Feed>({
    queryKey: ["chog.p4.feed", logAddr],
    queryFn: async () => {
      if (!publicClient || !deployed) {
        return { logBookCount: 0, entries: [], getLogsAvailable: false };
      }

      // 1) PRIMARY — entries via count()/entries(i). Always works.
      const count = (await publicClient.readContract({
        address: logAddr, abi: logBookAbi, functionName: "count",
      })) as bigint;
      const n = Number(count);
      const idxs = Array.from({ length: n }, (_, i) => BigInt(n - 1 - i)); // newest first

      const raw = await Promise.all(idxs.map(async (idx) => {
        const e = (await publicClient.readContract({
          address: logAddr, abi: logBookAbi, functionName: "entries", args: [idx],
        })) as readonly [bigint, bigint, bigint, bigint, bigint, bigint];
        return {
          seq: Number(idx),
          priceE8: e[0], bpsBefore: e[1], bpsAfter: e[2],
          navBefore: e[3], navAfter: e[4], ts: e[5],
        };
      }));

      // 2) SECONDARY — live-tail getLogs for tx-hash enrichment. Survive failure.
      let getLogsAvailable = true;
      const enrich = new Map<number, { blockNumber: bigint; txHash: `0x${string}` }>();
      try {
        const head = await publicClient.getBlockNumber();
        const fromBlock = head > LIVE_TAIL_BLOCKS ? head - LIVE_TAIL_BLOCKS : 0n;
        const loggedEvent = parseAbiItem(
          "event Logged(uint256 indexed seq, uint256 priceE8, uint256 bpsBefore, uint256 bpsAfter, uint256 navBefore, uint256 navAfter, uint256 ts)",
        ) as AbiEvent;
        const logs = await publicClient.getLogs({ address: logAddr, event: loggedEvent, fromBlock, toBlock: head });
        for (const l of logs) {
          const seq = (l as unknown as { args: { seq: bigint } }).args.seq;
          if (l.transactionHash && l.blockNumber != null) {
            enrich.set(Number(seq), { blockNumber: l.blockNumber, txHash: l.transactionHash });
          }
        }
      } catch (e) {
        getLogsAvailable = false;
        console.warn("[useP4Feed] getLogs failed — entries-only:", e instanceof Error ? e.message : e);
      }

      const entries: P4LogEntry[] = raw.map((e) => {
        const meta = enrich.get(e.seq);
        return { ...e, blockNumber: meta?.blockNumber, txHash: meta?.txHash, kind: classify(e) };
      });

      return { logBookCount: n, entries, getLogsAvailable };
    },
    enabled: !!publicClient,
    refetchInterval: visible ? 18_000 : false,
    refetchOnWindowFocus: true,
  });
}
