"use client";

import { VaultSummary } from "@/components/VaultSummary";
import { AllocationCard } from "@/components/AllocationCard";
import { AgentStatusCard } from "@/components/AgentStatusCard";
import { ProofFeed } from "@/components/ProofFeed";
import { VaultPanel } from "@/components/VaultPanel";

export function VaultDashboard() {
  return (
    <div className="space-y-6">
      <VaultSummary />
      <div className="grid gap-6 lg:grid-cols-3">
        {/* Left: allocation + agent + proof */}
        <div className="space-y-6 lg:col-span-2">
          <AllocationCard />
          <AgentStatusCard />
          <ProofFeed />
        </div>
        {/* Right: deposit / withdraw */}
        <div className="lg:sticky lg:top-24 lg:self-start">
          <VaultPanel />
        </div>
      </div>
    </div>
  );
}
