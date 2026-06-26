# chogfund — a self-driving MON/USDC vault

**Make money while you HODL your MON.**

*Monad testnet · illustrative. LP and parked-yield venues are mocks; treat numbers as demonstrative, not a live product. Not financial advice.*

---

## Abstract

chogfund is a non-custodial vault for people who believe in MON and don't want to sell it. You deposit MON; an autonomous, on-chain agent keeps your position balanced and productive — splitting between MON and USDC, providing concentrated liquidity, and parking idle capital in yield venues — while every move is priced by a trustless oracle and written to an on-chain proof book. You can withdraw your share, in-kind, at any time.

---

## The problem

Holding a volatile asset is a bet on direction. But volatility itself has value: an asset that swings around a level lets a disciplined rebalancer "buy low, sell high" mechanically. Most HODLers capture none of this — their MON simply sits in a wallet. Selling MON to chase yield means giving up the thing they believe in.

chogfund's premise: **volatility ≠ direction.** You can keep your conviction in MON *and* earn from its movement, without handing your coins to a custodian.

---

## How it works

1. **Deposit MON.** Your native MON is valued at the live Pyth price the moment you deposit (see *update-then-mint* below) and you receive vault shares.
2. **The agent allocates.** An autonomous keeper holds the vault near a 60/40 MON/USDC target, deploys a MON/USDC concentrated-liquidity (LP) position, and parks idle USDC/MON in yield venues — rebalancing only when it is worthwhile.
3. **Everything is priced trustlessly.** Net asset value (NAV) is computed from internal accounting valued at a fresh, confidence-checked Pyth MON/USD price — never from raw token balances, so a stray token transfer can't move your share price.
4. **Withdraw any time, in-kind.** Redemption returns your pro-rata MON + USDC directly. It needs no oracle and works even if the agent is paused — your funds are never trapped.

---

## Architecture

- **AllocatorVault** — an ERC-4626 vault (shares = `cvCHOG`) that extends a hardened core with three allocator legs: base MON/USDC, a MON/USDC LP position, and parked ERC-4626 vaults. NAV sums every leg exactly once.
- **HardenedVault (core)** — virtual-shares inflation guard, reentrancy protection, donation-resistant internal accounting, and a trustless price path. The agent's only powers are *allocate* and *rebalance* — it can never withdraw to itself.
- **PythPriceReader** — reads MON/USD from on-chain Pyth with staleness (max-age) and confidence checks; rejects stale or uncertain prices.
- **LpManager / VaultRouter / HealthMonitor** — manage the LP position, the whitelisted parked venues, and a graduated risk policy (caution → stress → emergency) that can flee a troubled venue or pull everything back to base.
- **LogBook** — an append-only on-chain record the vault writes itself on every action (price, allocation %, NAV before/after). The agent cannot forge it.

---

## Why your deposit is safe to price (update-then-mint)

Minting shares for a MON deposit requires an oracle — and a *stale* price could mint the wrong number of shares (diluting existing holders). chogfund closes this: `depositMON` makes you submit a **fresh Pyth update in the same transaction**. The price is pushed on-chain and read in one atomic step, so it is current by construction. A tiny oracle fee (a few wei) is bundled into your deposit; the staleness and confidence guards still apply.

---

## Three pillars

- **Non-custodial.** The agent can only allocate and rebalance — never move funds to an outside address. You redeem your own shares, in-kind.
- **Autonomous.** A keeper keeps the on-chain price fresh and rebalances only when it pays. A guardian kill-switch can pause the agent; withdrawals keep working while paused.
- **Provable.** Every action writes an on-chain LogBook entry. NAV, the allocation legs, and your position are read straight from the contract — not from a backend you have to trust.

---

## Testnet status & honesty

This deployment runs on **Monad testnet**. The Uniswap-style pool, position manager, and ERC-4626 yield venues are **faithful-interface mocks** with settable state — enough to demonstrate the full flow end-to-end, but **not** real integrations. Real concentrated-liquidity math, real venue behavior, real slippage and liquidity, and real LP valuation are validated at a later mainnet canary. Mock-green is not real-integration green.

---

## Roadmap

- **Now (testnet):** allocator vault + native-MON deposit + autonomous keeper + on-chain proof, end-to-end on mocks.
- **Next:** mainnet canary against real Uniswap v3 and real ERC-4626 venues; tightened oracle freshness with a production keeper; third-party review.

---

*chogfund is experimental software on a test network. Nothing here is financial advice.*
