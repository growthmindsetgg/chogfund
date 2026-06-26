import Link from "next/link";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ShieldCheck, Activity, FileCheck2, ArrowRight } from "lucide-react";
import { ParticleSphere } from "@/components/ParticleSphere";
import { MobileRedirect } from "@/components/MobileRedirect";
import { TestnetBadge } from "@/components/TestnetBadge";
import { Markdown } from "@/components/Markdown";
import { Card, CardContent } from "@/components/ui/card";

// Explainer / whitepaper landing at "/". Desktop only — phones are sent to /app
// by <MobileRedirect>. Static: the whitepaper is read at build time, and there
// are intentionally NO live on-chain numbers here.
export const dynamic = "force-static";

function whitepaperMarkdown(): string {
  try {
    return readFileSync(join(process.cwd(), "CHOGFUND_WHITEPAPER.md"), "utf8");
  } catch {
    return "# chogfund\n\nWhitepaper coming soon.";
  }
}

function Wordmark() {
  return (
    <span className="flex items-center gap-1.5 text-xl font-black lowercase tracking-tight text-[var(--black)]">
      <span className="text-[var(--purple)] leading-none" aria-hidden>◆</span>
      chogfund
    </span>
  );
}

function EnterCta({ className = "" }: { className?: string }) {
  return (
    <Link
      href="/app"
      className={`inline-flex items-center gap-2 rounded-xl bg-[var(--purple)] px-5 py-3 text-sm font-bold text-white shadow-sm transition-colors hover:bg-[var(--purple-strong)] ${className}`}
    >
      Enter dApp <ArrowRight className="size-4" />
    </Link>
  );
}

export default function Landing() {
  const whitepaper = whitepaperMarkdown();

  return (
    <>
      <MobileRedirect />

      {/* Mobile: brief splash while the redirect to /app fires. */}
      <div className="md:hidden monad-wash grid min-h-screen place-items-center px-6 text-center">
        <div>
          <Wordmark />
          <p className="mt-3 text-sm text-[var(--text-muted)]">Opening the app…</p>
          <Link href="/app" className="mt-4 inline-block text-sm font-semibold text-[var(--purple-strong)] underline">
            Tap to continue
          </Link>
        </div>
      </div>

      {/* Desktop: the explainer. */}
      <div className="monad-wash hidden min-h-screen flex-col text-[var(--text)] md:flex">
        <header className="sticky top-0 z-10 border-b border-[var(--border)] bg-[var(--bg)]/80 backdrop-blur">
          <div className="mx-auto flex max-w-5xl items-center justify-between gap-3 px-6 py-4">
            <Wordmark />
            <div className="flex items-center gap-4">
              <TestnetBadge />
              <EnterCta className="px-4 py-2" />
            </div>
          </div>
        </header>

        <main className="mx-auto w-full max-w-5xl flex-1 px-6">
          {/* Hero */}
          <section className="grid grid-cols-2 items-center gap-8 py-16">
            <div>
              <TestnetBadge className="mb-5" />
              <h1 className="text-balance text-5xl font-black leading-[1.05] tracking-tight text-[var(--blue)]">
                You believe in MON? Then make money while you HODL your MON
              </h1>
              <p className="mt-5 max-w-md text-balance text-lg text-[var(--text-muted)]">
                A non-custodial vault that keeps your MON working — balanced, providing liquidity, and earning yield —
                while an autonomous on-chain agent proves every move. Withdraw any time.
              </p>
              <div className="mt-8 flex items-center gap-4">
                <EnterCta />
                <a href="#whitepaper" className="text-sm font-semibold text-[var(--purple-strong)] hover:underline">
                  Read the whitepaper ↓
                </a>
              </div>
            </div>
            <div className="flex justify-center">
              <div className="aspect-square w-[300px] lg:w-[360px]">
                <ParticleSphere color="#836EF9" count={460} period={42} />
              </div>
            </div>
          </section>

          {/* Plain-language sections */}
          <section className="grid grid-cols-2 gap-10 border-t border-[var(--border)] py-14">
            <div>
              <h2 className="text-2xl font-extrabold tracking-tight text-[var(--blue)]">Volatility ≠ direction</h2>
              <p className="mt-3 leading-relaxed text-[var(--text-muted)]">
                Holding MON is a bet on direction. But its swings have value: a disciplined rebalancer mechanically buys
                low and sells high around a level. Most HODLers capture none of that — their MON just sits there.
              </p>
            </div>
            <div>
              <h2 className="text-2xl font-extrabold tracking-tight text-[var(--blue)]">Keep your MON, earn from it</h2>
              <p className="mt-3 leading-relaxed text-[var(--text-muted)]">
                Deposit MON and receive vault shares. An autonomous agent holds a 60/40 MON/USDC target, runs a
                concentrated-liquidity position, and parks idle capital in yield venues — rebalancing only when it pays.
                You never give up custody.
              </p>
            </div>
          </section>

          {/* 3 pillars */}
          <section className="border-t border-[var(--border)] py-14">
            <Card>
              <CardContent className="grid grid-cols-3 gap-8 py-8">
                <Pillar icon={<ShieldCheck className="size-5" />} title="Non-custodial">
                  The agent can only allocate &amp; rebalance — never withdraw to itself. You redeem your own shares, in-kind.
                </Pillar>
                <Pillar icon={<Activity className="size-5" />} title="Autonomous">
                  A keeper keeps the on-chain price fresh and rebalances only when worthwhile. A kill-switch pauses the
                  agent; withdrawals keep working while paused.
                </Pillar>
                <Pillar icon={<FileCheck2 className="size-5" />} title="Provable">
                  Every action writes an on-chain LogBook entry. NAV, allocation and your position are read straight from
                  the contract — no backend to trust.
                </Pillar>
              </CardContent>
            </Card>
          </section>

          {/* Whitepaper */}
          <section id="whitepaper" className="border-t border-[var(--border)] py-14">
            <div className="mb-6 text-xs font-semibold uppercase tracking-widest text-[var(--purple-strong)]">Whitepaper</div>
            <article className="rounded-[var(--radius-card)] border border-[var(--border)] bg-white p-8 [box-shadow:var(--shadow-card)]">
              <Markdown source={whitepaper} />
            </article>
          </section>

          {/* Press / links stub */}
          <section className="border-t border-[var(--border)] py-14">
            <h2 className="text-2xl font-extrabold tracking-tight text-[var(--blue)]">Press &amp; links</h2>
            <p className="mt-2 text-sm text-[var(--text-muted)]">More coming soon.</p>
            <div className="mt-5 flex flex-wrap gap-3">
              {[
                { label: "GitHub", href: "#" },
                { label: "X / Twitter", href: "#" },
                { label: "Docs", href: "#whitepaper" },
                { label: "Monad", href: "https://monad.xyz" },
              ].map((l) => (
                <a
                  key={l.label}
                  href={l.href}
                  className="rounded-xl border border-[var(--border)] bg-white px-4 py-2 text-sm font-semibold text-[var(--text)] hover:bg-[var(--purple-soft)]"
                >
                  {l.label}
                </a>
              ))}
            </div>
          </section>

          {/* Closing CTA */}
          <section className="border-t border-[var(--border)] py-16 text-center">
            <h2 className="text-balance text-3xl font-black tracking-tight text-[var(--blue)]">
              Make money while you HODL your MON.
            </h2>
            <div className="mt-6 flex justify-center">
              <EnterCta />
            </div>
          </section>
        </main>

        <footer className="mx-auto w-full max-w-5xl px-6 py-10 text-center text-xs text-[var(--text-muted)]">
          Monad testnet · LP &amp; parked venues are mocks (illustrative). Non-custodial — funds remain withdrawable while
          paused. Not financial advice.
        </footer>
      </div>
    </>
  );
}

function Pillar({ icon, title, children }: { icon: React.ReactNode; title: string; children: React.ReactNode }) {
  return (
    <div>
      <div className="flex items-center gap-2 text-[var(--purple-strong)]">
        <span className="grid size-9 place-items-center rounded-xl bg-[var(--purple-soft)]">{icon}</span>
        <span className="text-sm font-bold text-[var(--text)]">{title}</span>
      </div>
      <p className="mt-2 text-sm leading-relaxed text-[var(--text-muted)]">{children}</p>
    </div>
  );
}
