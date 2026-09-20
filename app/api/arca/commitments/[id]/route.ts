import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";

import { record } from "@/lib/arca/usage";
import { isResponse, requireSession } from "@/lib/commitments/auth";
import { acceptCommitment, deleteCommitment, getCommitment, setScope } from "@/lib/commitments/store";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Ctx = { params: Promise<{ id: string }> };

const Patch = z.discriminatedUnion("action", [
  z.object({ action: z.literal("accept") }),
  z.object({ action: z.literal("scope"), start: z.number().int().min(0), end: z.number().int().min(0) }),
]);

export async function GET(request: NextRequest, ctx: Ctx) {
  const session = await requireSession(request);
  if (isResponse(session)) return session;
  const { id } = await ctx.params;
  const detail = await getCommitment(session.userId, id);
  if (!detail) return NextResponse.json({ error: "not found" }, { status: 404 });
  return NextResponse.json({ item: detail });
}

export async function PATCH(request: NextRequest, ctx: Ctx) {
  const session = await requireSession(request);
  if (isResponse(session)) return session;
  const { id } = await ctx.params;
  const parsed = Patch.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "invalid action" }, { status: 400 });
  const detail =
    parsed.data.action === "accept"
      ? await acceptCommitment(session.userId, id)
      : await setScope(session.userId, id, parsed.data.start, parsed.data.end);
  if (!detail) return NextResponse.json({ error: "not found" }, { status: 404 });
  if (parsed.data.action === "accept") {
    await record({ userId: session.userId, organizationId: session.organizationId, kind: "task_tossed", ok: true });
  }
  return NextResponse.json({ item: detail });
}

export async function DELETE(request: NextRequest, ctx: Ctx) {
  const session = await requireSession(request);
  if (isResponse(session)) return session;
  const { id } = await ctx.params;
  const ok = await deleteCommitment(session.userId, id);
  return NextResponse.json({ ok });
}
