export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { and, eq } from "drizzle-orm";

import { resolveOwner } from "@/lib/brain/owner";
import { db } from "@/lib/db/client";
import { memoryPages } from "@/lib/db/schema";

type Ctx = { params: Promise<{ slug: string[] }> };

// docs/ARCA-BRAIN.md §4 — slug is multi-segment (people/kim-cs), hence [...slug].
export async function GET(req: Request, ctx: Ctx): Promise<Response> {
  const client = db();
  if (!client) return Response.json({ error: "ARCA Brain has no database configured" }, { status: 503 });

  const owner = await resolveOwner(req);
  if (!owner) return Response.json({ error: "unauthorized" }, { status: 401 });

  const { slug: segments } = await ctx.params;
  const slug = segments.join("/");

  const [page] = await client
    .select()
    .from(memoryPages)
    .where(and(eq(memoryPages.owner, owner), eq(memoryPages.slug, slug)))
    .limit(1);
  if (!page) return Response.json({ error: "not found" }, { status: 404 });

  return Response.json({
    slug: page.slug,
    title: page.title,
    summary: page.summary,
    body: page.body,
    edges: page.edges,
    updatedAt: page.updatedAt.toISOString(),
  });
}
