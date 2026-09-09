export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { deviceIdFromRequest } from "@/lib/arca/device";
import { record, TRACTION_KINDS, type UsageKind } from "@/lib/arca/usage";
import { resolveOwner } from "@/lib/brain/owner";

interface EventInput { kind?: unknown; at?: unknown; ok?: unknown }

// Batch traction events from the apps. Same auth as /api/brain/remember;
// each event becomes one usage_events row scoped by Brain owner.
export async function POST(req: Request): Promise<Response> {
  const owner = await resolveOwner(req);
  if (!owner) return Response.json({ error: "unauthorized" }, { status: 401 });

  let body: { events?: unknown };
  try {
    body = (await req.json()) as { events?: unknown };
  } catch {
    return Response.json({ error: "invalid json" }, { status: 400 });
  }
  const raw = Array.isArray(body.events) ? (body.events as EventInput[]) : [];
  if (raw.length < 1 || raw.length > 100) {
    return Response.json({ error: "events must be an array of 1 to 100 items" }, { status: 400 });
  }

  const deviceId = deviceIdFromRequest(req) ?? undefined;
  let accepted = 0;
  let skipped = 0;
  for (const e of raw) {
    const kind = typeof e.kind === "string" ? (e.kind as UsageKind) : null;
    if (!kind || !TRACTION_KINDS.has(kind)) { skipped++; continue; }
    await record({ owner, deviceId, kind, ok: e.ok !== false });
    accepted++;
  }
  return Response.json({ accepted, skipped });
}
