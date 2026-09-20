import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";

import { record } from "@/lib/arca/usage";
import { isResponse, requireSession } from "@/lib/commitments/auth";
import { extractCommitments } from "@/lib/commitments/llm";
import { createFromExtraction, listCommitments } from "@/lib/commitments/store";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 120;

const Body = z.object({
  text: z.string().trim().min(20).max(60000),
  kind: z.enum(["text", "recording"]).default("text"),
});

/** transcript → summary + commitments (persisted as `detected`). */
export async function POST(request: NextRequest) {
  const session = await requireSession(request);
  if (isResponse(session)) return session;
  const parsed = Body.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "대화 내용을 20자 이상 붙여넣어 주세요." }, { status: 400 });
  const extraction = await extractCommitments(parsed.data.text);
  const ids = await createFromExtraction(session.userId, extraction, { kind: parsed.data.kind, transcript: parsed.data.text });
  await record({ userId: session.userId, organizationId: session.organizationId, kind: "meeting_captured", ok: true });
  const all = await listCommitments(session.userId);
  return NextResponse.json({
    provider: extraction.provider,
    summary: extraction.summary,
    ids,
    items: all.filter((c) => ids.includes(c.id)),
  });
}
