// Persistent honesty badge. The P4 venues (Uniswap LP, ERC4626 parked vaults)
// are MOCKS on testnet — this must never read as a live mainnet product.
export function TestnetBadge({ className = "" }: { className?: string }) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full border border-[var(--berry)]/30 bg-[var(--berry)]/8 px-2.5 py-1 text-[11px] font-semibold tracking-wide text-[var(--berry)] ${className}`}
      title="Monad testnet. Uniswap LP + ERC4626 parked venues are mocks — illustrative, not real integration."
    >
      <span className="size-1.5 rounded-full bg-[var(--berry)]" aria-hidden />
      TESTNET · ILLUSTRATIVE
    </span>
  );
}
