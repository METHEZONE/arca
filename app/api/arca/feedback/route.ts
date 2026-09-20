import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";

import { isResponse, requireSession } from "@/lib/commitments/auth";
import { addFeedback, tasteModel } from "@/lib/commitments/store";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const Body = z.object({
  commitmentId: z.string().uuid().optional(),
  nodeId: z.string().uuid().optional(),
  rail: z.enum(["consent", "quality"]),
  value: z.string().min(1).max(80),
  note: z.string().max(500).optional(),
});

/** Two rails, never merged: consent (맡길 것/묻고 할 것/하지 말 것) · quality (맞았다/수정 필요). */
export async function POST(request: NextRequest) {
  const session = await requireSession(request);
  if (isResponse(session)) return session;
  const parsed = Body.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "invalid feedback" }, { status: 400 });
  await addFeedback(session.userId, parsed.data);
  return NextResponse.json({ taste: await tasteModel(session.userId) });
}
