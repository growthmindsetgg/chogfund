"use client";

// usePythLive — independent browser-side fetch of MON/USD from Pyth Hermes.
// Used by the header PriceBadge to detect when the on-chain pushed price
// (PythPriceReader.readPriceE8()) is stale (no pyth-pusher running). NEVER
// drives NAV directly — NAV is computed from the on-chain priceE8 only.
//
// P8 reconciliation: this MUST use the SAME source the contract reads, so the
// displayed "live" comparison is apples-to-apples with the on-chain price.
// The P4 PythPriceReader reads the STABLE Pyth contract with feed
// 0x3149…6cd1, so we fetch the STABLE Hermes endpoint (addresses.pythHermes)
// for that same feed (addresses.monUsdFeedId) — NOT the beta endpoint/feed.

import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import addresses from "@addresses";

interface HermesPrice {
  price: string;
  expo: number;
  conf: string;
  publish_time: number;
}
interface HermesResp {
  parsed?: Array<{ id: string; price: HermesPrice }>;
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

async function fetchMonUsdE8(): Promise<bigint> {
  const url = new URL("/v2/updates/price/latest", addresses.pythHermes);
  url.searchParams.append("ids[]", addresses.monUsdFeedId);
  url.searchParams.set("parsed", "true");
  url.searchParams.set("encoding", "hex");

  const res = await fetch(url.toString(), { headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`Hermes ${res.status}`);

  const body = (await res.json()) as HermesResp;
  const entry = body.parsed?.[0];
  if (!entry) throw new Error("Hermes: missing parsed[0]");

  const raw = BigInt(entry.price.price);
  if (raw <= 0n) throw new Error("Hermes: non-positive price");

  // Normalize to 8 decimals (priceE8).
  const shift = entry.price.expo + 8;
  if (shift === 0) return raw;
  if (shift > 0)  return raw * 10n ** BigInt(shift);
  return raw / 10n ** BigInt(-shift);
}

export function usePythLive() {
  const visible = useVisible();
  return useQuery<bigint>({
    queryKey: ["pyth-live", addresses.monUsdFeedId],
    queryFn: fetchMonUsdE8,
    refetchInterval: visible ? 12_000 : false,
    refetchOnWindowFocus: true,
    staleTime: 8_000,
    retry: 1,
  });
}
