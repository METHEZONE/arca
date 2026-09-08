/**
 * Weekly recap email (Phase F, "irreversibility"): the honest version of
 * "ARCA remembered this for you" that's buildable from what the server
 * actually has. Meeting content and extracted decisions live only in each
 * device's local SwiftData store (see `apps/arca/.../MemoryModels.swift`) —
 * nothing about *what* was said reaches this backend, only that a call was
 * made and how long it took (`usage_events`). So the recap is a usage
 * digest ("3.2 hours transcribed across 6 sessions this week"), not a
 * content digest. A real "here's what you decided" email needs session
 * summaries synced server-side first — a product decision, not built here.
 */

import { SignJWT, jwtVerify } from "jose";
import { and, eq, gte, sql } from "drizzle-orm";

import { db } from "@/lib/db/client";
import { organizations, users, usageEvents } from "@/lib/db/schema";

const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
// Re-send guard: a week's cron firing twice (retry, manual trigger) must not
// double-mail the same org — 6 days (not 7) tolerates the schedule drifting
// a little without ever sending twice inside one real week.
const RESEND_GUARD_MS = 6 * 24 * 60 * 60 * 1000;

function secretKey(): Uint8Array {
  const s = process.env.ARCA_SESSION_SECRET?.trim();
  if (!s) throw new Error("ARCA_SESSION_SECRET is not set.");
  return new TextEncoder().encode(s);
}

/** Long-lived on purpose — an unsubscribe link in an old, unread email must
 *  still work months later. */
export async function signUnsubscribeToken(userId: string): Promise<string> {
  return new SignJWT({ purpose: "digest-unsub", userId })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime("400d")
    .sign(secretKey());
}

export async function verifyUnsubscribeToken(token: string): Promise<string | null> {
  try {
    const { payload } = await jwtVerify(token, secretKey());
    if (payload.purpose !== "digest-unsub" || typeof payload.userId !== "string") return null;
    return payload.userId;
  } catch {
    return null;
  }
}

export interface OrgWeekStats {
  organizationId: string;
  sessionCount: number;
  audioHours: number;
}

/** Orgs with any transcribe activity in the last 7 days and no digest sent
 *  within the resend guard window — the cron's actual worklist. */
async function orgsDueForDigest(): Promise<OrgWeekStats[]> {
  const database = db();
  if (!database) return [];

  const weekAgo = new Date(Date.now() - WEEK_MS);
  const guardCutoff = new Date(Date.now() - RESEND_GUARD_MS);

  const rows = await database
    .select({
      organizationId: usageEvents.organizationId,
      sessionCount: sql<number>`count(*) filter (where ${usageEvents.kind} = 'transcribe')::int`,
      audioSeconds: sql<number>`coalesce(sum(${usageEvents.audioSeconds}), 0)`,
    })
    .from(usageEvents)
    .innerJoin(organizations, eq(organizations.id, usageEvents.organizationId))
    .where(
      and(
        gte(usageEvents.at, weekAgo),
        sql`${usageEvents.organizationId} is not null`,
        sql`(${organizations.digestSentAt} is null or ${organizations.digestSentAt} < ${guardCutoff})`,
      ),
    )
    .groupBy(usageEvents.organizationId);

  return rows
    .filter((r): r is typeof r & { organizationId: string } => Boolean(r.organizationId))
    .filter((r) => r.sessionCount > 0)
    .map((r) => ({
      organizationId: r.organizationId,
      sessionCount: r.sessionCount,
      audioHours: Math.round((r.audioSeconds / 3600) * 10) / 10,
    }));
}

async function sendDigestEmail(email: string, stats: OrgWeekStats, unsubscribeUrl: string): Promise<boolean> {
  const key = process.env.RESEND_API_KEY?.trim();
  if (!key) return false;
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: process.env.RING_FROM_EMAIL?.trim() || "ARCA <onboarding@resend.dev>",
        to: [email],
        subject: `Your week with ARCA: ${stats.sessionCount} session${stats.sessionCount === 1 ? "" : "s"} remembered`,
        html: `
          <p>This week ARCA sat in on <strong>${stats.sessionCount} session${stats.sessionCount === 1 ? "" : "s"}</strong>
          and transcribed <strong>${stats.audioHours} hour${stats.audioHours === 1 ? "" : "s"}</strong> for you.</p>
          <p>Open the app to revisit what it caught.</p>
          <p style="color:#888;font-size:12px;margin-top:32px;">
            <a href="${unsubscribeUrl}">Unsubscribe from this weekly recap</a>
          </p>
        `,
      }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

export interface DigestRunResult {
  orgsDue: number;
  emailsSent: number;
  orgsMarkedSent: number;
}

/** The cron entrypoint. Never throws — one org's email failure (bad address,
 *  Resend outage) must not stop the rest of the batch or crash the request. */
export async function sendWeeklyDigests(originForLinks: string): Promise<DigestRunResult> {
  const database = db();
  if (!database) return { orgsDue: 0, emailsSent: 0, orgsMarkedSent: 0 };

  const due = await orgsDueForDigest();
  let emailsSent = 0;
  let orgsMarkedSent = 0;

  for (const stats of due) {
    // Claim before sending, not after: if marking-sent fails post-send, a
    // retry would re-mail every recipient. If claiming succeeds but sending
    // then fails, the worst case is one skipped week — safer than duplicate
    // email.
    try {
      await database
        .update(organizations)
        .set({ digestSentAt: new Date() })
        .where(eq(organizations.id, stats.organizationId));
      orgsMarkedSent += 1;
    } catch (err) {
      console.error("arca.digest.claim_failed", stats.organizationId, err instanceof Error ? err.message : err);
      continue;
    }

    try {
      const recipients = await database
        .select({ id: users.id, email: users.email })
        .from(users)
        .where(and(eq(users.organizationId, stats.organizationId), eq(users.digestOptOut, false)));

      for (const user of recipients) {
        const token = await signUnsubscribeToken(user.id);
        const unsubscribeUrl = `${originForLinks}/api/arca/digest/unsubscribe?token=${token}`;
        const ok = await sendDigestEmail(user.email, stats, unsubscribeUrl);
        if (ok) emailsSent += 1;
      }
    } catch (err) {
      console.error("arca.digest.org_failed", stats.organizationId, err instanceof Error ? err.message : err);
    }
  }

  return { orgsDue: due.length, emailsSent, orgsMarkedSent };
}

export interface LifetimeStats {
  sessionCount: number;
  audioHours: number;
}

/** Lifetime totals for `/api/arca/me` — the "memory count" surface, sourced
 *  from the same usage_events truth the digest and quota checks use. */
export async function lifetimeStats(organizationId: string): Promise<LifetimeStats | null> {
  const database = db();
  if (!database) return null;
  try {
    const [row] = await database
      .select({
        sessionCount: sql<number>`count(*) filter (where ${usageEvents.kind} = 'transcribe')::int`,
        audioSeconds: sql<number>`coalesce(sum(${usageEvents.audioSeconds}), 0)`,
      })
      .from(usageEvents)
      .where(eq(usageEvents.organizationId, organizationId));
    return {
      sessionCount: row?.sessionCount ?? 0,
      audioHours: Math.round(((row?.audioSeconds ?? 0) / 3600) * 10) / 10,
    };
  } catch (err) {
    console.error("arca.digest.lifetime_stats_failed", err instanceof Error ? err.message : err);
    return null;
  }
}
