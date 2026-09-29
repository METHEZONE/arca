import { and, eq, gte, sql } from "drizzle-orm";

import { record, type UsageKind } from "@/lib/arca/usage";
import { isFreeTier } from "@/lib/cloud";
import { db } from "@/lib/db/client";
import { usageEvents } from "@/lib/db/schema";

// Spend brake for ARCA Cloud: every proxied call is one usage_events row
// under the caller's Brain owner, and a caller over its minute/day budget
// gets a 429 before we touch a provider. Personal invites get more room
// than anonymous free-tier devices.
// ponytail: count(*) per request, fine for a beta; Redis if traffic grows.
const LIMITS: Partial<Record<UsageKind, { perMinute: number; perDay: number; invitePerDay: number }>> = {
  chat: { perMinute: 30, perDay: 400, invitePerDay: 1500 },
  delegate: { perMinute: 120, perDay: 3000, invitePerDay: 6000 }, // Composio (connect polling is chatty)
  realtime: { perMinute: 4, perDay: 40, invitePerDay: 150 },
  // One request per ~5-minute chunk (plus the odd gap re-check): 400/day is
  // ~30 hours of audio on a free-tier device.
  transcribe: { perMinute: 40, perDay: 400, invitePerDay: 1500 },
};

export async function meterCloud(
  email: string,
  kind: UsageKind,
  extra: { model?: string; audioSeconds?: number } = {},
): Promise<Response | null> {
  const owner = `email:${email}`;
  const limits = LIMITS[kind];
  const database = db();
  if (limits && database) {
    try {
      const count = async (since: number) => {
        const [{ n }] = await database
          .select({ n: sql<number>`count(*)::int` })
          .from(usageEvents)
          .where(and(eq(usageEvents.owner, owner), eq(usageEvents.kind, kind), gte(usageEvents.at, new Date(Date.now() - since))));
        return n;
      };
      const perDay = isFreeTier(email) ? limits.perDay : limits.invitePerDay;
      if ((await count(60_000)) >= limits.perMinute || (await count(86_400_000)) >= perDay) {
        return Response.json(
          { type: "error", error: { type: "rate_limit_error", message: "ARCA Cloud 사용량 한도에 닿았어요. 잠시 뒤에 다시 시도해 주세요." } },
          { status: 429, headers: { "retry-after": "60" } },
        );
      }
    } catch (err) {
      // A metering hiccup must not take the beta down — fail open.
      console.error("arca.cloud.meter_failed", err instanceof Error ? err.message : err);
    }
  }
  await record({ owner, kind, ok: true, ...extra });
  return null;
}
