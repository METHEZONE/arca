import { NextRequest, NextResponse } from "next/server";

import { record } from "@/lib/arca/usage";
import { isResponse, requireSession } from "@/lib/commitments/auth";
import { runCommitment } from "@/lib/commitments/store";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 120;

/** Advances the graph until the next human gate / missing evidence. */
export async function POST(request: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const session = await requireSession(request);
  if (isResponse(session)) return session;
  const { id } = await ctx.params;
  const { detail, events } = await runCommitment(session.userId, id);
  if (!detail) return NextResponse.json({ error: "not found" }, { status: 404 });
  await record({ userId: session.userId, organizationId: session.organizationId, kind: "auto_executed", ok: true });
  return NextResponse.json({ item: detail, events });
}
