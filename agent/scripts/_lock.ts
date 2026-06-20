// _lock.ts — one-writer lock for OracleAMM.setPrice.
//
// Both scripts that write setPrice (price-driver.ts and pyth-pusher.ts) MUST
// acquire this lock at start and release it on exit. Two concurrent writers
// fight over the same slot and the oracle ends up flapping between their
// targets — the failure mode the spec called out.
//
// The lock is a JSON file at agent/.writer.lock containing { pid, script,
// startedAt }. A second writer that finds the lock checks if the recorded PID
// is still alive (process.kill(pid, 0)); if not, the lock is stale and gets
// reclaimed.

import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
export const LOCK_PATH = resolve(here, "..", ".writer.lock");

interface LockData {
  pid: number;
  script: string;
  startedAt: number;
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e: unknown) {
    const code = (e as NodeJS.ErrnoException).code;
    if (code === "ESRCH") return false; // no such process
    if (code === "EPERM") return true;  // exists but we lack perms
    return false;
  }
}

export class WriterConflictError extends Error {
  constructor(public other: LockData) {
    super(
      `Another writer holds the lock: ${other.script} (pid ${other.pid}, since ${new Date(other.startedAt).toISOString()}).\n` +
      `  Stop it before starting this script. If you're certain it's a ghost, delete ${LOCK_PATH}.`,
    );
    this.name = "WriterConflictError";
  }
}

export function acquireWriterLock(script: string): void {
  if (existsSync(LOCK_PATH)) {
    let data: LockData | null = null;
    try { data = JSON.parse(readFileSync(LOCK_PATH, "utf8")) as LockData; }
    catch { /* corrupt; reclaim */ }
    if (data) {
      if (pidAlive(data.pid)) throw new WriterConflictError(data);
      console.warn(`[lock] reclaiming stale lock from ${data.script} (pid ${data.pid})`);
    } else {
      console.warn(`[lock] corrupt lock file; reclaiming`);
    }
  }
  const data: LockData = { pid: process.pid, script, startedAt: Date.now() };
  writeFileSync(LOCK_PATH, JSON.stringify(data, null, 2));
  console.log(`[lock] acquired by ${script} (pid ${process.pid})`);
}

export function releaseWriterLock(): void {
  try {
    if (!existsSync(LOCK_PATH)) return;
    const data = JSON.parse(readFileSync(LOCK_PATH, "utf8")) as LockData;
    if (data.pid === process.pid) {
      unlinkSync(LOCK_PATH);
      console.log("[lock] released");
    }
  } catch {
    // best-effort; if release fails, next start will detect stale PID
  }
}

/**
 * Install signal + beforeExit handlers that run onExit() then release the
 * lock. Re-entry safe; subsequent signals are ignored while shutdown is in
 * flight. Returns a function to manually flag shutdown so the main loop can
 * notice (cooperative cancel).
 */
export function installExitHooks(onExit: () => Promise<void> | void): {
  shouldStop: () => boolean;
} {
  let stopping = false;
  let exiting  = false;

  const handler = async (sig: string) => {
    if (exiting) return;
    if (sig === "SIGINT" || sig === "SIGTERM" || sig === "SIGBREAK") {
      stopping = true;
      console.log(`\n[exit] ${sig} received — finishing current tick…`);
      // Give the loop a chance to notice + finish. If we get a SECOND signal,
      // hard exit.
      if (exiting === false) {
        process.once(sig as NodeJS.Signals, () => {
          console.warn(`[exit] ${sig} received again — hard exit`);
          releaseWriterLock();
          process.exit(130);
        });
      }
      return;
    }
    exiting = true;
    try { await Promise.resolve(onExit()); }
    catch (e) { console.error("[exit] onExit error:", e instanceof Error ? e.message : e); }
    finally { releaseWriterLock(); }
  };

  process.on("SIGINT",   () => void handler("SIGINT"));
  process.on("SIGTERM",  () => void handler("SIGTERM"));
  process.on("SIGBREAK", () => void handler("SIGBREAK"));
  process.on("beforeExit", () => void handler("beforeExit"));

  return { shouldStop: () => stopping };
}

/** Absolute value for BigInt. */
export function abs(x: bigint): bigint { return x < 0n ? -x : x; }
