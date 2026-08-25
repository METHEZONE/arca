/**
 * Quota + rate-limit enforcement (Phase 4), keyed by the same subject usage
 * is recorded against: an organization for a signed-in tenant, a device id
 * for anonymous use (see `lib/arca/identity.ts` — a bare device is metered
 * as the implicit free tier so quota can't be dodged by skipping sign-in).
 *
 * Both checks query `usage_events` directly rather than a counter table or
 * Redis. That's a `count(*)` per request on top of the insert this route
 * already does, which is fine at this app's scale (a small team's beta) and
 * reuses infra that's already there instead of adding a new dependency.
 *
 * ponytail: DB-backed counting, not a proper token bucket — a burst right at
 * a minute boundary can slip through. Upgrade path if throughput ever
 * matters: Upstash Redis with a sliding-window or token-bucket algorithm.
 */

import { and, eq, gte, sql } from "drizzle-orm";

import { db } from "@/lib/db/client";
import { organizations, usageEvents } from "@/lib/db/schema";
import type { Identity } from "@/lib/arca/identity";
import { limitsFor, type Plan } from "@/lib/arca/plans";

export interface QuotaSubject {
  scope: "organization" | "device";
  id: string;
  plan: Plan;
}

export async function resolveQuotaSubject(identity: Identity): Promise<QuotaSubject> {
  if (identity.kind === "device") {
    return { scope: "device", id: identity.deviceId, plan: "free" };
  }
  const database = db();
  let plan: Plan = "free";
  if (database) {
    const [org] = await database
      .select({ plan: organizations.plan })
      .from(organizations)
      .where(eq(organizations.id, identity.organizationId))
      .limit(1);
    if (org) plan = org.plan;
  }
  return { scope: "organization", id: identity.organizationId, plan };
}

export type QuotaDenial =
  | { reason: "rate_limited"; retryAfterSeconds: number; limit: number }
  | { reason: "quota_exceeded"; limit: number; plan: Plan };

/** Returns null when the request may proceed, or the reason it can't. */
export async function checkQuota(subject: QuotaSubject): Promise<QuotaDenial | null> {
  const database = db();
  // No DB configured: usage isn't durable, so there's nothing to count
  // against — fail open, same posture as usage.ts's own degradation.
  if (!database) return null;

  const limits = limitsFor(subject.plan);
  const subjectFilter =
    subject.scope === "organization"
      ? eq(usageEvents.organizationId, subject.id)
      : and(eq(usageEvents.deviceId, subject.id), sql`${usageEvents.organizationId} is null`);

  const oneMinuteAgo = new Date(Date.now() - 60_000);
  const [{ value: recentCount }] = await database
    .select({ value: sql<number>`count(*)::int` })
    .from(usageEvents)
    .where(and(subjectFilter, gte(usageEvents.at, oneMinuteAgo)));
  if (recentCount >= limits.requestsPerMinute) {
    return { reason: "rate_limited", retryAfterSeconds: 60, limit: limits.requestsPerMinute };
  }

  const startOfMonth = new Date(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(), 1));
  const [{ value: monthCount }] = await database
    .select({ value: sql<number>`count(*)::int` })
    .from(usageEvents)
    .where(and(subjectFilter, gte(usageEvents.at, startOfMonth)));
  if (monthCount >= limits.monthlyRequests) {
    return { reason: "quota_exceeded", limit: limits.monthlyRequests, plan: subject.plan };
  }

  return null;
}

/** Shared 429 body shape for both chat and transcribe. */
export function quotaDenialResponseBody(denial: QuotaDenial) {
  if (denial.reason === "rate_limited") {
    return {
      error: `Too many requests — limit is ${denial.limit}/minute. Try again shortly.`,
      code: "rate_limited",
      retryAfterSeconds: denial.retryAfterSeconds,
    };
  }
  return {
    error: `Monthly quota exceeded — the ${denial.plan} plan includes ${denial.limit} requests/month.`,
    code: "quota_exceeded",
    plan: denial.plan,
    limit: denial.limit,
  };
}
