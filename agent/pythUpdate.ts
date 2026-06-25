import { PYTH_HERMES_URL, MON_USD_FEED_ID } from "./config.js";

// Fetches the binary VAA update data AND the parsed price from Hermes in one
// call. The update data is what gets pushed on-chain via
// PythPriceReader.updatePrice{value: fee}(updateData); the parsed price mirrors
// what readPriceE8() will return after the push.

export interface MonUsdUpdate {
  priceE8: bigint;          // normalized 8-decimal MON/USD
  rawPrice: bigint;         // Pyth raw int
  expo: number;
  conf: bigint;             // same scale as rawPrice
  confBps: bigint;          // conf/price in bps
  publishTime: number;      // unix seconds
  updateData: `0x${string}`[]; // bytes[] for updatePriceFeeds / getUpdateFee
}

function toE8(raw: bigint, expo: number): bigint {
  const shift = expo + 8;
  if (shift === 0) return raw;
  if (shift > 0) return raw * 10n ** BigInt(shift);
  return raw / 10n ** BigInt(-shift);
}

export async function getMonUsdUpdate(): Promise<MonUsdUpdate> {
  const url = new URL("/v2/updates/price/latest", PYTH_HERMES_URL);
  url.searchParams.append("ids[]", MON_USD_FEED_ID);
  url.searchParams.set("parsed", "true");
  url.searchParams.set("encoding", "hex");

  const res = await fetch(url, { headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`Hermes ${res.status} ${res.statusText}`);

  const body = (await res.json()) as {
    binary?: { data?: string[] };
    parsed?: Array<{ price: { price: string; conf: string; expo: number; publish_time: number } }>;
  };

  const entry = body.parsed?.[0];
  const dataArr = body.binary?.data;
  if (!entry) throw new Error("Hermes: parsed[0] missing");
  if (!dataArr || dataArr.length === 0) throw new Error("Hermes: binary.data missing");

  const rawPrice = BigInt(entry.price.price);
  if (rawPrice <= 0n) throw new Error(`Hermes: non-positive price ${rawPrice}`);
  const conf = BigInt(entry.price.conf);
  const expo = entry.price.expo;

  const updateData = dataArr.map((d) => (d.startsWith("0x") ? d : `0x${d}`) as `0x${string}`);
  const confBps = (conf * 10_000n) / rawPrice;

  return {
    priceE8: toE8(rawPrice, expo),
    rawPrice,
    expo,
    conf,
    confBps,
    publishTime: entry.price.publish_time,
    updateData,
  };
}
