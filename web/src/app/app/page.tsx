"use client";

import Link from "next/link";
import { useAccount } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import addresses from "@addresses";
import { PriceBadge } from "@/components/PriceBadge";
import { TestnetBadge } from "@/components/TestnetBadge";
import { Connect } from "@/components/Connect";
import { VaultDashboard } from "@/components/VaultDashboard";

const ZERO = "0x0000000000000000000000000000000000000000";

export default function AppPage() {
  const { isConnected } = useAccount();
  const notDeployed = addresses.AllocatorVault.toLowerCase() === ZERO;

  return (
    <div className="monad-wash min-h-screen text-[var(--text)]">
      <header className="sticky top-0 z-10 border-b border-[var(--border)] bg-[var(--bg)]/80 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-3 px-5 py-4">
          <div className="flex items-center gap-2.5">
            <Link href="/" className="flex items-center gap-1.5 text-xl font-black lowercase tracking-tight text-[var(--black)]">
              <span className="text-[var(--purple)] leading-none" aria-hidden>◆</span>
              chogfund
            </Link>
            <PriceBadge />
          </div>
          <div className="flex items-center gap-3">
            <TestnetBadge className="hidden sm:inline-flex" />
            <ConnectButton showBalance={false} chainStatus="icon" />
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-5 py-8 sm:py-10">
        {notDeployed ? (
          <div className="rounded-2xl border border-[var(--border)] bg-white p-4 text-sm">
            <span className="font-semibold text-[var(--purple-strong)]">No deployment loaded.</span>{" "}
            <code className="font-mono text-xs">src/addresses.json</code> has no AllocatorVault address.
          </div>
        ) : isConnected ? (
          <VaultDashboard />
        ) : (
          <Connect />
        )}
      </main>

      <footer className="mx-auto max-w-6xl px-5 py-10 text-center text-xs text-[var(--text-muted)]">
        Monad testnet · LP &amp; parked venues are mocks (illustrative). Non-custodial — funds remain withdrawable while paused.
        Not financial advice.
      </footer>
    </div>
  );
}
