export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { and, eq, ilike, isNull, or } from "drizzle-orm";

import { resolveOwner } from "@/lib/brain/owner";
import { db } from "@/lib/db/client";
import { memoryEntries, memoryPages } from "@/lib/db/schema";

const MAX_RESULTS = 20;

// docs/ARCA-BRAIN.md §4 — ILIKE, not pgvector (that's v2). Korean text
// doesn't tokenize well for full-text search anyway, so substring is fine.
export async function GET(req: Request): Promise<Response> {
  const client = db();
  if (!client) return Response.json({ error: "ARCA Brain has no database configured" }, { status: 503 });

  const owner = await resolveOwner(req);
  if (!owner) return Response.json({ error: "unauthorized" }, { status: 401 });

  const q = new URL(req.url).searchParams.get("q")?.trim() ?? "";
  if (!q) return Response.json({ pages: [], entries: [] });
  const pattern = `%${q}%`;

  const pages = await client
    .select({
      slug: memoryPages.slug,
      title: memoryPages.title,
      summary: memoryPages.summary,
      updatedAt: memoryPages.updatedAt,
    })
    .from(memoryPages)
    .where(
      and(
        eq(memoryPages.owner, owner),
        or(ilike(memoryPages.title, pattern), ilike(memoryPages.summary, pattern), ilike(memoryPages.body, pattern)),
      ),
    )
    .limit(MAX_RESULTS);

  const entries = await client
    .select({
      id: memoryEntries.id,
      text: memoryEntries.text,
      source: memoryEntries.source,
      createdAt: memoryEntries.createdAt,
    })
    .from(memoryEntries)
    .where(and(eq(memoryEntries.owner, owner), isNull(memoryEntries.deletedAt), ilike(memoryEntries.text, pattern)))
    .limit(MAX_RESULTS);

  return Response.json({
    pages: pages.map((p) => ({ ...p, updatedAt: p.updatedAt.toISOString() })),
    entries: entries.map((e) => ({ ...e, createdAt: e.createdAt.toISOString() })),
  });
}
