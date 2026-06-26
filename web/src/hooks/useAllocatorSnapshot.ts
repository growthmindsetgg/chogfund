"use client";

import { useEffect, useState } from "react";
import { useAccount, usePublicClient } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import addresses from "@addresses";
import { allocatorAbi, pythReaderAbi, usdcAbi } from "@/abi";

// P8 STEP 1 — read layer against the P4 AllocatorVault.
//
// The AllocatorVault is an ERC4626 (asset = USDC, 6 dec; shares = cvCHOG,
// 12 dec). NAV is `totalAssets()` (USDC 6dec) built from INTERNAL accounting
// (tracked MON + tracked USDC + allocator legs) — never balanceOf — so a token
// donation cannot move share price. Allocation legs come from two on-chain
// trace views the contract exposes:
//   navBreakdown() -> (baseUsdc, baseMonValue, legsValue, total)
//   legBreakdown() -> (lpValue, parkedValue)         // legsValue == lp + parked
// so the four display legs are: baseUsdc, baseMonValue, lpValue, parkedValue,
// and they sum to total == totalAssets() == NAV.
//
// RPC discipline carried over from P3: NO Multicall3 on Monad testnet — viem
// fans out individual reads; we poll on an interval and pause when hidden.

const ZERO = "0x0000000000000000000000000000000000000000" as const;

export interface AllocatorSnapshot {
  // vault-wide
  nav: bigint;            // totalAssets(), USDC 6dec
  totalShares: bigint;    // totalSupply(), 12dec
  shareDecimals: number;  // decimals() — 12
  sharePriceUsdc: bigint; // convertToAssets(1 whole share), USDC 6dec
  priceE8: bigint;        // PythPriceReader.readPriceE8(), 8dec USD/MON
  trackedMon: bigint;     // wei, 18dec
  trackedUsdc: bigint;    // 6dec
  paused: boolean;
  owner: `0x${string}` | null;
  agent: `0x${string}` | null;
  // allocation legs (all USDC 6dec, sum == nav)
  baseUsdc: bigint;
  baseMonValue: bigint;
  lpValue: bigint;
  parkedValue: bigint;
  // wiring
  lpManager: `0x${string}` | null;
  vaultRouter: `0x${string}` | null;
  healthMonitor: `0x${string}` | null;
  // user position
  userShares: bigint;
  userValueUsdc: bigint;  // previewRedeem(userShares), USDC 6dec
  userMonBalance: bigint; // native MON wallet balance, wei
  userUsdcBalance: bigint; // USDC wallet balance, 6dec
  userUsdcAllowance: bigint; // USDC allowance to the vault, 6dec
}

const EMPTY: AllocatorSnapshot = {
  nav: 0n, totalShares: 0n, shareDecimals: 12, sharePriceUsdc: 0n, priceE8: 0n,
  trackedMon: 0n, trackedUsdc: 0n, paused: false, owner: null, agent: null,
  baseUsdc: 0n, baseMonValue: 0n, lpValue: 0n, parkedValue: 0n,
  lpManager: null, vaultRouter: null, healthMonitor: null,
  userShares: 0n, userValueUsdc: 0n, userMonBalance: 0n, userUsdcBalance: 0n,
  userUsdcAllowance: 0n,
};

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

export function useAllocatorSnapshot() {
  const { address } = useAccount();
  const publicClient = usePublicClient();
  const visible = useVisible();

  const vault  = addresses.AllocatorVault as `0x${string}`;
  const reader = addresses.PythPriceReader as `0x${string}`;
  const usdc   = addresses.MockUSDC as `0x${string}`;
  const deployed = vault.toLowerCase() !== ZERO;
  const userAddr = (address ?? ZERO) as `0x${string}`;
  const hasUser = userAddr.toLowerCase() !== ZERO;

  return useQuery<AllocatorSnapshot>({
    queryKey: ["chog.p4.snapshot", vault, userAddr],
    queryFn: async () => {
      if (!publicClient || !deployed) return EMPTY;

      const av = { address: vault, abi: allocatorAbi } as const;

      const [
        nav, totalShares, shareDecimals, paused, owner, agent,
        trackedMon, trackedUsdc, lpManager, vaultRouter, healthMonitor,
        navBreakdown, legBreakdown, priceE8,
      ] = await Promise.all([
        publicClient.readContract({ ...av, functionName: "totalAssets" }),
        publicClient.readContract({ ...av, functionName: "totalSupply" }),
        publicClient.readContract({ ...av, functionName: "decimals" }),
        publicClient.readContract({ ...av, functionName: "paused" }),
        publicClient.readContract({ ...av, functionName: "owner" }),
        publicClient.readContract({ ...av, functionName: "agent" }),
        publicClient.readContract({ ...av, functionName: "trackedMon" }),
        publicClient.readContract({ ...av, functionName: "trackedUsdc" }),
        publicClient.readContract({ ...av, functionName: "lpManager" }),
        publicClient.readContract({ ...av, functionName: "vaultRouter" }),
        publicClient.readContract({ ...av, functionName: "healthMonitor" }),
        publicClient.readContract({ ...av, functionName: "navBreakdown" }),
        publicClient.readContract({ ...av, functionName: "legBreakdown" }),
        // readPriceE8 reverts if the Pyth price is stale/low-confidence; tolerate it.
        publicClient.readContract({ address: reader, abi: pythReaderAbi, functionName: "readPriceE8" })
          .catch(() => 0n),
      ]);

      const dec = Number(shareDecimals as number);
      const oneShare = 10n ** BigInt(dec);
      const sharePriceUsdc = (await publicClient.readContract({
        ...av, functionName: "convertToAssets", args: [oneShare],
      })) as bigint;

      const [baseUsdc, baseMonValue] =
        navBreakdown as readonly [bigint, bigint, bigint, bigint];
      const [lpValue, parkedValue] = legBreakdown as readonly [bigint, bigint];

      // user position
      let userShares = 0n, userValueUsdc = 0n, userMonBalance = 0n,
          userUsdcBalance = 0n, userUsdcAllowance = 0n;
      if (hasUser) {
        const [shares, monBal, usdcBal, allowance] = await Promise.all([
          publicClient.readContract({ ...av, functionName: "balanceOf", args: [userAddr] }),
          publicClient.getBalance({ address: userAddr }),
          publicClient.readContract({ address: usdc, abi: usdcAbi, functionName: "balanceOf", args: [userAddr] }),
          publicClient.readContract({ address: usdc, abi: usdcAbi, functionName: "allowance", args: [userAddr, vault] }),
        ]);
        userShares = shares as bigint;
        userMonBalance = monBal as bigint;
        userUsdcBalance = usdcBal as bigint;
        userUsdcAllowance = allowance as bigint;
        userValueUsdc = userShares > 0n
          ? ((await publicClient.readContract({ ...av, functionName: "previewRedeem", args: [userShares] })) as bigint)
          : 0n;
      }

      return {
        nav: nav as bigint,
        totalShares: totalShares as bigint,
        shareDecimals: dec,
        sharePriceUsdc,
        priceE8: priceE8 as bigint,
        trackedMon: trackedMon as bigint,
        trackedUsdc: trackedUsdc as bigint,
        paused: paused as boolean,
        owner: owner as `0x${string}`,
        agent: agent as `0x${string}`,
        baseUsdc, baseMonValue, lpValue, parkedValue,
        lpManager: lpManager as `0x${string}`,
        vaultRouter: vaultRouter as `0x${string}`,
        healthMonitor: healthMonitor as `0x${string}`,
        userShares, userValueUsdc, userMonBalance, userUsdcBalance, userUsdcAllowance,
      } as AllocatorSnapshot;
    },
    enabled: !!publicClient,
    refetchInterval: visible ? 12_000 : false,
    refetchOnWindowFocus: true,
    placeholderData: (prev) => prev ?? EMPTY,
  });
}
