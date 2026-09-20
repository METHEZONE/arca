import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";

import { record } from "@/lib/arca/usage";
import { isResponse, requireSession } from "@/lib/commitments/auth";
import { actOnNode } from "@/lib/commitments/store";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const Body = z.discriminatedUnion("type", [
  z.object({ type: z.literal("approve") }),
  z.object({ type: z.literal("edit"), artifact: z.string().min(1).max(20000) }),
  z.object({ type: z.literal("reject"), note: z.string().max(500).optional() }),
  z.object({
    type: z.literal("evidence"),
    text: z.string().trim().min(3).max(4000),
    kind: z.enum(["reply", "url", "calendar", "payment", "delivery", "other"]),
  }),
]);

export async function POST(request: NextRequest, ctx: { params: Promise<{ id: string; nodeId: string }> }) {
  const session = await requireSession(request);
  if (isResponse(session)) return session;
  const { id, nodeId } = await ctx.params;
  const parsed = Body.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "invalid action" }, { status: 400 });
  const detail = await actOnNode(session.userId, id, nodeId, parsed.data);
  if (!detail) return NextResponse.json({ error: "not found" }, { status: 404 });
  const kind = parsed.data.type === "approve" ? "proposal_approved" : parsed.data.type === "reject" ? "proposal_rejected" : detail.status === "verified" ? "loop_closed" : undefined;
  if (kind) await record({ userId: session.userId, organizationId: session.organizationId, kind, ok: true });
  return NextResponse.json({ item: detail });
}
