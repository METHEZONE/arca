export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { and, eq, isNull, sql } from "drizzle-orm";

import { resolveOwner } from "@/lib/brain/owner";
import { db } from "@/lib/db/client";
import { memoryEntries } from "@/lib/db/schema";

interface RememberEntryInput {
  text?: unknown;
  kind?: unknown;
  source?: unknown;
  sourceRef?: unknown;
  deviceId?: unknown;
  createdAt?: unknown;
}

// docs/ARCA-BRAIN.md §4 — append-only buffer writes. Duplicate exact-text
// entries (same owner, not deleted) are skipped rather than re-inserted.
export async function POST(req: Request): Promise<Response> {
  const client = db();
  if (!client) return Response.json({ error: "ARCA Brain has no database configured" }, { status: 503 });

  const owner = await resolveOwner(req);
  if (!owner) return Response.json({ error: "unauthorized" }, { status: 401 });

  let body: { entries?: unknown };
  try {
    body = (await req.json()) as { entries?: unknown };
  } catch {
    return Response.json({ error: "invalid json" }, { status: 400 });
  }

  const rawEntries = Array.isArray(body.entries) ? (body.entries as RememberEntryInput[]) : [];
  if (rawEntries.length < 1 || rawEntries.length > 50) {
    return Response.json({ error: "entries must be an array of 1 to 50 items" }, { status: 400 });
  }

  let inserted = 0;
  let skipped = 0;
  for (const raw of rawEntries) {
    const text = typeof raw.text === "string" ? raw.text.trim() : "";
    if (text.length < 1 || text.length > 500) {
      skipped++;
      continue;
    }

    const [dup] = await client
      .select({ id: memoryEntries.id })
      .from(memoryEntries)
      .where(and(eq(memoryEntries.owner, owner), eq(memoryEntries.text, text), isNull(memoryEntries.deletedAt)))
      .limit(1);
    if (dup) {
      skipped++;
      continue;
    }

    const createdAt =
      typeof raw.createdAt === "string" && !Number.isNaN(new Date(raw.createdAt).getTime())
        ? new Date(raw.createdAt)
        : new Date();

    await client.insert(memoryEntries).values({
      owner,
      text,
      kind: typeof raw.kind === "string" && raw.kind ? raw.kind : "fact",
      source: typeof raw.source === "string" && raw.source ? raw.source : "chat",
      sourceRef: typeof raw.sourceRef === "string" ? raw.sourceRef : null,
      deviceId: typeof raw.deviceId === "string" ? raw.deviceId : null,
      createdAt,
    });
    inserted++;
  }

  const [pendingRow] = await client
    .select({ count: sql<number>`count(*)` })
    .from(memoryEntries)
    .where(
      and(eq(memoryEntries.owner, owner), isNull(memoryEntries.consolidatedAt), isNull(memoryEntries.deletedAt)),
    );

  return Response.json({ inserted, skipped, pending: Number(pendingRow?.count ?? 0) });
}
