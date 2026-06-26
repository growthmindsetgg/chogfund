import addresses from "@addresses";

// fetchMonUsdUpdateData — pulls the latest STABLE-Hermes binary VAA for MON/USD,
// the bytes[] `priceUpdate` argument depositMON pushes on-chain in the same tx
// (update-then-mint). Stable endpoint/feed — the same source the contract reads;
// the on-chain Pyth REJECTS beta VAAs.
export async function fetchMonUsdUpdateData(): Promise<`0x${string}`[]> {
  const url = new URL("/v2/updates/price/latest", addresses.pythHermes);
  url.searchParams.append("ids[]", addresses.monUsdFeedId);
  url.searchParams.set("encoding", "hex");

  const res = await fetch(url.toString(), { headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`Hermes ${res.status}`);

  const body = (await res.json()) as { binary?: { data?: string[] } };
  const data = body.binary?.data;
  if (!Array.isArray(data) || data.length === 0) throw new Error("Hermes: missing binary.data");

  return data.map((d) => (d.startsWith("0x") ? d : `0x${d}`) as `0x${string}`);
}
