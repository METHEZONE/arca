/**
 * Usage records — the traction instrument, now durable.
 *
 * Every model call already passes through this server, so this log *is* the
 * "how many people actually use it, how much" number. It used to be a
 * single-line JSON console log because Vercel's filesystem is ephemeral and
 * there was no database to lose it to; now there is one (see `lib/db`), and
 * `record` writes into `usage_events` scoped by device/user/organization so
 * quota checks (`lib/arca/quota.ts`) can query it.
 *
 * Falls back to the old console-log behavior when `DATABASE_URL` isn't set,
 * matching the rest of this repo's "works with zero keys, upgrades the
 * moment a key is present" posture.
 */

import { db } from "@/lib/db/client";
import { usageEvents } from "@/lib/db/schema";

export type UsageKind = "chat" | "transcribe";

export interface UsageEvent {
  at: string;
  deviceId?: string;
  /** Set once a request is tenant-authenticated (Phase 2 session). */
  userId?: string;
  organizationId?: string;
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
 * Still emitted as a single-line `arca.usage` JSON log first — cheap,
 * synchronous with the request, and useful for `vercel logs` debugging even
 * once the DB is the source of truth for quota/billing. A telemetry failure
 * (including the DB write) must never take down the request that produced it.
 */
export async function record(event: Omit<UsageEvent, "at">): Promise<void> {
  const full: UsageEvent = { at: new Date().toISOString(), ...event };
  try {
    console.log(`arca.usage ${JSON.stringify(full)}`);
  } catch {
    /* ignore */
  }

  const database = db();
  if (!database) return;
  try {
    await database.insert(usageEvents).values({
      at: new Date(full.at),
      deviceId: full.deviceId,
      userId: full.userId,
      organizationId: full.organizationId,
      kind: full.kind,
      model: full.model,
      inputTokens: full.inputTokens,
      outputTokens: full.outputTokens,
      audioSeconds: full.audioSeconds,
      ok: full.ok,
      error: full.error,
    });
  } catch (err) {
    console.error("arca.usage.db_write_failed", err instanceof Error ? err.message : err);
  }
}
