export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { and, desc, eq, isNull } from "drizzle-orm";

import { resolveOwner } from "@/lib/brain/owner";
import { db } from "@/lib/db/client";
import { memoryEntries, memoryPages, memoryViews } from "@/lib/db/schema";

const MAX_BUFFER = 40;
const MAX_PAGES = 60;

// docs/ARCA-BRAIN.md §4 — everything a chat system prompt needs, in one call.
export async function GET(req: Request): Promise<Response> {
  const client = db();
  if (!client) return Response.json({ error: "ARCA Brain has no database configured" }, { status: 503 });

  const owner = await resolveOwner(req);
  if (!owner) return Response.json({ error: "unauthorized" }, { status: 401 });

  let latest: Date | null = null;
  const track = (d: Date) => {
    if (!latest || d > latest) latest = d;
  };

  const viewRows = await client.select().from(memoryViews).where(eq(memoryViews.owner, owner));
  const views = { essentials: "", threads: "", recent: "" } as Record<string, string>;
  for (const v of viewRows) {
    views[v.name] = v.body;
    track(v.updatedAt);
  }

  const bufferRows = await client
    .select({ text: memoryEntries.text, source: memoryEntries.source, createdAt: memoryEntries.createdAt })
    .from(memoryEntries)
    .where(
      and(eq(memoryEntries.owner, owner), isNull(memoryEntries.consolidatedAt), isNull(memoryEntries.deletedAt)),
    )
    .orderBy(desc(memoryEntries.createdAt))
    .limit(MAX_BUFFER);
  bufferRows.forEach((e) => track(e.createdAt));

  const pageRows = await client
    .select({
      slug: memoryPages.slug,
      title: memoryPages.title,
      summary: memoryPages.summary,
      updatedAt: memoryPages.updatedAt,
    })
    .from(memoryPages)
    .where(eq(memoryPages.owner, owner))
    .orderBy(desc(memoryPages.updatedAt))
    .limit(MAX_PAGES);
  pageRows.forEach((p) => track(p.updatedAt));

  return Response.json({
    views,
    buffer: bufferRows.map((e) => ({ text: e.text, source: e.source, createdAt: e.createdAt.toISOString() })),
    pages: pageRows.map((p) => ({
      slug: p.slug,
      title: p.title,
      summary: p.summary,
      updatedAt: p.updatedAt.toISOString(),
    })),
    updatedAt: (latest ?? new Date(0)).toISOString(),
  });
}
