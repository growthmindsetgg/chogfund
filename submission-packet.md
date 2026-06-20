# Chog Vault — Monad Blitz Mumbai submission packet

> This file is the input you (the human) copy/paste into the
> `blitz.devnads.com` portal. Claude prepared it but **does NOT** auto-submit
> the portal form — that step is yours.

---

## Project Title
**Chog Vault**

## Description (2–3 sentences)
Chog Vault is a non-custodial 60/40 MON/USDC vault on Monad testnet kept in band by an autonomous, non-LLM on-chain agent. The agent has exactly one power — sign `rebalance()` when MON drifts outside ±5% of the target — and cannot deposit, withdraw, or set arbitrary prices; every rebalance is written trustlessly by the vault itself to an on-chain `LogBook`, so the proof exists in chain state, not in a server log. Built for the Agent Economy track: an agent that holds its own key, follows a hard-coded strategy, and leaves a tamper-evident audit trail.

## Team Members
- **Durgesh Pandey** — GitHub [@growthmindsetgg](https://github.com/growthmindsetgg) (deploy + fork; pushed this submission)
- **Shradda Kadam** — GitHub [@zuzu2109](https://github.com/zuzu2109)

## GitHub URL
https://github.com/growthmindsetgg/chog-vault

## Demo URL
https://chog-vault.vercel.app

## Category
**DeFi** (framed as DeFi × AI Agents — the protocol is a constant-mix vault; the differentiator is the autonomous agent + on-chain proof book).

## Project Image
`submission-image.png` at the repo root — 1200 × 630, Chog Vault wordmark on the official `#F6F5FB` background with `#6B5CF0` accent. **Optional**: replace with a real screenshot of the **Agent** tab on the live site (live feed + on-chain LogBook proof panel) for a stronger pitch image. Run `cd web && npm run dev`, navigate to the Agent tab, and screenshot it at 1200×630 to overwrite.

---

## On-chain proof references (helpful for judges)

Monad testnet, chainId 10143. Explorer: https://testnet.monadscan.com

| Contract | Address |
|---|---|
| `RebalanceVault` | [`0xBeF5aC62EC233773B06A85fdcA6abdB30C3cFcC4`](https://testnet.monadscan.com/address/0xBeF5aC62EC233773B06A85fdcA6abdB30C3cFcC4) |
| `OracleAMM`      | [`0x733e3977FdF6504BFC0F047Eeb468C960260BA79`](https://testnet.monadscan.com/address/0x733e3977FdF6504BFC0F047Eeb468C960260BA79) |
| `LogBook`        | [`0x220885f455FE78C72f02050B2Bc791B83AadF907`](https://testnet.monadscan.com/address/0x220885f455FE78C72f02050B2Bc791B83AadF907) |
| `MockUSDC`       | [`0xAcA4F378d7b10228e83Ab7a6A38547484789EA9a`](https://testnet.monadscan.com/address/0xAcA4F378d7b10228e83Ab7a6A38547484789EA9a) |

Sample rebalance transactions (signed by `AGENT_PK` `0xd461…48Ce`):
- [76.9% → 60.0% at $2.00](https://testnet.monadscan.com/tx/0x690c157011028d6008fc17715451b848fcea8ae8a6bd29a2b3a6d4dd608f4640)
- [67.7% → 60.0% at $2.80](https://testnet.monadscan.com/tx/0x94a2a2de3e3370c13614fb25d1a204bccdf842cf6d8ab35b28f0f591e60653e9)

Each rebalance writes one `LogBook.Logged` event in the same transaction with `priceE8`, `bpsBefore`, `bpsAfter`, `navBefore`, `navAfter`, `ts`.

---

## Agent-Economy framing (one paragraph)

The agent is a 200-line TypeScript program that holds its own throwaway `AGENT_PK`, reads the on-chain MON/USD price every ~10 seconds, runs a pure `decide()` strategy, and — when off-band — signs exactly one transaction. That transaction calls `RebalanceVault.rebalance()`, which is the only function the vault grants the agent. The vault then writes the proof of its own NAV-before / NAV-after / bps-before / bps-after to a separate `LogBook` contract in the *same* transaction. There is no admin path that lets the agent withdraw, no off-chain database that lets the agent revise history, and no key in the deployed web bundle. This is what an autonomous-agent-driven primitive looks like when you take the trust assumptions seriously.

---

## How a judge can verify in 90 seconds

1. Open https://chog-vault.vercel.app, connect a wallet on Monad testnet.
2. **Agent tab** — pulsing purple dot = agent active; the rebalance feed has links straight to MonadScan; the "On-chain proof" panel renders LogBook entries directly from chain state.
3. **Kill switch** — connect with the deployer wallet (`0xCBdf…b48e`) and the rose button activates. Engage it → rebalances stop. Crucially, Dashboard → Withdraw **still works** while paused — funds are not trapped.
4. Inspect [`RebalanceVault.sol`](https://github.com/growthmindsetgg/chog-vault/blob/main/contracts/src/RebalanceVault.sol) and [`LogBook.sol`](https://github.com/growthmindsetgg/chog-vault/blob/main/contracts/src/LogBook.sol):
   - `deposit()` and `withdraw()` both `require(msg.sender != agent)` — agent cannot move funds.
   - `LogBook.record(...)` is `onlyVault` — agent cannot forge entries.
   - `setPaused()` does not gate `withdraw()` — kill switch is not a fund trap.

---

## Notes for the portal form
- **Description box**: paste the "Description (2–3 sentences)" section verbatim.
- **Category**: choose **DeFi**.
- **GitHub** / **Demo URL**: as listed above.
- **Project Image**: upload `submission-image.png` (or your Agent-tab screenshot replacement).
- **Team Members**: enter the two names + GitHub handles above.

The Blitz portal at `blitz.devnads.com` is login + time-gated + manual; Claude does not submit it. The information you need lives in this file.
