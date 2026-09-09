export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { and, gte, inArray, isNotNull } from "drizzle-orm";

import { TRACTION_KINDS } from "@/lib/arca/usage";
import { aggregate } from "@/lib/brain/metrics";
import { resolveOwner } from "@/lib/brain/owner";
import { db } from "@/lib/db/client";
import { usageEvents } from "@/lib/db/schema";

const DEFAULT_SINCE = "2026-09-01";

// Founder-only read of the traction aggregate for the IR-Day dashboard.
export async function GET(req: Request): Promise<Response> {
  const client = db();
  if (!client) return Response.json({ error: "ARCA Brain has no database configured" }, { status: 503 });

  const owner = await resolveOwner(req);
  const allowed = process.env.BRAIN_METRICS_OWNER?.trim() || "email:me@thezonebio.com";
  if (!owner) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (owner !== allowed) return Response.json({ error: "forbidden" }, { status: 403 });

  const url = new URL(req.url);
  const sinceParam = url.searchParams.get("since") ?? DEFAULT_SINCE;
  const since = new Date(sinceParam);
  if (Number.isNaN(since.getTime())) return Response.json({ error: "invalid since" }, { status: 400 });

  const rows = await client
    .select({ owner: usageEvents.owner, kind: usageEvents.kind, at: usageEvents.at })
    .from(usageEvents)
    .where(and(isNotNull(usageEvents.owner), inArray(usageEvents.kind, [...TRACTION_KINDS]), gte(usageEvents.at, new Date(since.getTime() - 30 * 86_400_000))));

  const metrics = aggregate(
    rows.map((r) => ({ owner: r.owner as string, kind: r.kind, at: r.at })),
    new Date(),
    since,
  );
  return Response.json(metrics);
}
