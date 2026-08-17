/**
 * Per-device usage records — the traction instrument.
 *
 * The beta's whole purpose is a number: of the people who installed ARCA, how
 * many actually use it, and how much. Every model call already passes through
 * this server, so the proxy log *is* that number — there is no separate
 * analytics pipeline to build.
 *
 * Storage is deliberately best-effort. Vercel's filesystem is ephemeral, so a
 * write here can be lost; that is fine for a usage counter and unacceptable for
 * a balance, which is why balances are not kept here. When durable storage
 * arrives (KV, Postgres), `record` is the single function to reimplement.
 */

export type UsageKind = "chat" | "transcribe";

export interface UsageEvent {
  at: string;
  deviceId: string;
  kind: UsageKind;
  /** Model that served it, for cost attribution. */
  model?: string;
  inputTokens?: number;
  outputTokens?: number;
  /** Audio length for transcription, so "time spent with ARCA" is computable. */
  audioSeconds?: number;
  ok: boolean;
  /** Present when `ok` is false. Short — no request bodies. */
  error?: string;
}

/**
 * Records one event.
 *
 * Emitted as a single-line JSON log with a stable `arca.usage` prefix so it can
 * be grepped out of `vercel logs` today, before any database exists:
 *
 *     vercel logs --since 24h | grep arca.usage
 */
export async function record(event: Omit<UsageEvent, "at">): Promise<void> {
  const full: UsageEvent = { at: new Date().toISOString(), ...event };
  // A telemetry failure must never take down the request that produced it.
  try {
    console.log(`arca.usage ${JSON.stringify(full)}`);
  } catch {
    /* ignore */
  }
}
