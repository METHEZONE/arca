export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { and, eq } from "drizzle-orm";

import { resolveOwner } from "@/lib/brain/owner";
import { db } from "@/lib/db/client";
import { memoryEntries } from "@/lib/db/schema";

type Ctx = { params: Promise<{ id: string }> };

// docs/ARCA-BRAIN.md §4 — soft delete only; the buffer/archive stays append-only.
export async function DELETE(req: Request, ctx: Ctx): Promise<Response> {
  const client = db();
  if (!client) return Response.json({ error: "ARCA Brain has no database configured" }, { status: 503 });

  const owner = await resolveOwner(req);
  if (!owner) return Response.json({ error: "unauthorized" }, { status: 401 });

  const { id } = await ctx.params;

  const [row] = await client
    .update(memoryEntries)
    .set({ deletedAt: new Date() })
    .where(and(eq(memoryEntries.id, id), eq(memoryEntries.owner, owner)))
    .returning({ id: memoryEntries.id });

  if (!row) return Response.json({ error: "not found" }, { status: 404 });
  return Response.json({ ok: true });
}
