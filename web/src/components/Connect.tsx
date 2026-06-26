"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import { ShieldCheck, Activity, FileCheck2 } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { VaultSummary } from "@/components/VaultSummary";
import { TestnetBadge } from "@/components/TestnetBadge";
import { ParticleSphere } from "@/components/ParticleSphere";

// Connect screen — shown when no wallet is connected. Still surfaces live NAV /
// share price (public reads need no wallet) so the vault isn't a blank wall.
export function Connect() {
  return (
    <div className="space-y-8">
      <div className="text-center">
        {/* Hero focal visual — decorative rotating purple dotted globe, sitting
            directly on the off-white page (no disc, no glow). Pure decoration
            (NOT an agent-status indicator). */}
        <div className="mx-auto mb-7 aspect-square w-[208px] sm:w-[256px]">
          <ParticleSphere color="#836EF9" count={460} period={42} />
        </div>

        <TestnetBadge className="mb-5" />
        <h1 className="text-balance text-4xl font-black tracking-tight text-[var(--blue)] sm:text-5xl">
          A self-driving MON/USDC vault
        </h1>
        <p className="mx-auto mt-4 max-w-xl text-balance text-lg text-[var(--text-muted)]">
          Deposit MON. An autonomous on-chain agent allocates across MON, USDC, an LP leg and
          parked yield — and proves every move on-chain. Non-custodial, withdraw any time.
        </p>
        <div className="mt-7 flex justify-center">
          <ConnectButton showBalance={false} chainStatus="icon" />
        </div>
      </div>

      <VaultSummary />

      <Card>
        <CardContent className="grid gap-6 py-6 sm:grid-cols-3">
          <Feature icon={<ShieldCheck className="size-5" />} title="Non-custodial">
            The agent can only allocate &amp; rebalance — never withdraw to itself. You redeem in-kind.
          </Feature>
          <Feature icon={<Activity className="size-5" />} title="Autonomous">
            Pyth-anchored NAV checks gate every move. A kill switch pauses the agent; funds stay withdrawable.
          </Feature>
          <Feature icon={<FileCheck2 className="size-5" />} title="Provable">
            Every action writes a LogBook entry on-chain. NAV and allocation are read straight from the contract.
          </Feature>
        </CardContent>
      </Card>
    </div>
  );
}

function Feature({ icon, title, children }: { icon: React.ReactNode; title: string; children: React.ReactNode }) {
  return (
    <div>
      <div className="flex items-center gap-2 text-[var(--purple-strong)]">
        <span className="grid size-9 place-items-center rounded-xl bg-[var(--purple-soft)]">{icon}</span>
        <span className="text-sm font-bold text-[var(--text)]">{title}</span>
      </div>
      <p className="mt-2 text-sm text-[var(--text-muted)]">{children}</p>
    </div>
  );
}
