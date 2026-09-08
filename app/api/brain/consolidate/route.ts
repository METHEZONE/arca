export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

import { timingSafeEqual } from "node:crypto";

import Anthropic from "@anthropic-ai/sdk";

import { consolidateDueOwners, consolidateOwnerNow } from "@/lib/brain/consolidate";
import { resolveOwner } from "@/lib/brain/owner";
import { anthropicKey } from "@/lib/config";
import { db } from "@/lib/db/client";

function safeEqual(a: string, b: string): boolean {
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  return bufA.length === bufB.length && timingSafeEqual(bufA, bufB);
}

// docs/ARCA-BRAIN.md §4 — two callers share one route. Device tokens are
// always shaped "d1.<id>.<sig>" (lib/arca/device.ts), so a bearer value that
// isn't shaped that way is presumed to be an attempted CRON_SECRET rather
// than a device credential.
export async function POST(req: Request): Promise<Response> {
  const client = db();
  if (!client) return Response.json({ error: "ARCA Brain has no database configured" }, { status: 503 });

  const key = anthropicKey();
  if (!key) return Response.json({ error: "ARCA Brain has no model key configured" }, { status: 500 });
  const anthropic = new Anthropic({ apiKey: key });

  const authHeader = req.headers.get("authorization");
  const bearer = authHeader?.toLowerCase().startsWith("bearer ") ? authHeader.slice(7).trim() : null;
  const looksLikeCron = Boolean(bearer) && !bearer!.startsWith("d1.");

  if (looksLikeCron) {
    const cronSecret = process.env.CRON_SECRET?.trim();
    if (!cronSecret) return Response.json({ error: "CRON_SECRET is not configured" }, { status: 400 });
    if (!safeEqual(bearer!, cronSecret)) return Response.json({ error: "unauthorized" }, { status: 401 });

    const runs = await consolidateDueOwners(client, anthropic);
    return Response.json({ runs });
  }

  const owner = await resolveOwner(req);
  if (!owner) return Response.json({ error: "unauthorized" }, { status: 401 });

  const run = await consolidateOwnerNow(client, anthropic, owner);
  return Response.json({ runs: [run] });
}
