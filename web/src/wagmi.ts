import { defineChain, fallback, http } from "viem";
import { createConfig } from "wagmi";
import { getDefaultConfig, getDefaultWallets } from "@rainbow-me/rainbowkit";
import addresses from "@addresses";

export const EXPLORER_BASE: string = addresses.explorerBase;
export const DEPLOY_BLOCK: number   = addresses.deployBlock;
export const CHAIN_ID: number       = addresses.chainId;
export const RPC_PRIMARY: string    = process.env.NEXT_PUBLIC_RPC_URL ?? addresses.rpc;
export const RPC_FALLBACK: string   = addresses.rpcFallback ?? addresses.rpc;

// Monad testnet — Multicall3 deliberately UNSET. Official testnet has no
// Multicall3; calling through one 429-storms the RPC.
export const monadTestnet = defineChain({
  id: CHAIN_ID,
  name: "Monad Testnet",
  nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 },
  rpcUrls: {
    default: { http: [RPC_PRIMARY] },
  },
  blockExplorers: {
    default: { name: "MonadScan", url: EXPLORER_BASE },
  },
  testnet: true,
});

// Single wagmi/RainbowKit config. multicall disabled on the client; viem will
// fan out individual reads even when wagmi tries to batch.
export const config = getDefaultConfig({
  appName: "chogfund",
  // RainbowKit requires a projectId for WalletConnect; placeholder is fine for
  // testnet (WalletConnect just won't initialize without a real one).
  projectId: process.env.NEXT_PUBLIC_WC_PROJECT_ID ?? "chog-vault-demo",
  chains: [monadTestnet],
  transports: {
    [monadTestnet.id]: fallback([http(RPC_PRIMARY), http(RPC_FALLBACK)]),
  },
  ssr: true,
  batch: { multicall: false },
});

// Re-exported for downstream usage.
export { getDefaultWallets };
export { createConfig };
