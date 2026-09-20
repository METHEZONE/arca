import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";

import { isResponse, requireSession } from "@/lib/commitments/auth";
import { confirmProfile, deleteProfile, getProfile } from "@/lib/commitments/profile";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const SourceSchema = z.object({
  kind: z.enum(["google", "gravatar", "domain", "user"]),
  label: z.string().max(200),
  url: z.string().max(400).optional(),
  confidence: z.number().min(0).max(1),
});
const Body = z.object({
  displayName: z.string().max(120).nullable(),
  headline: z.string().max(200).nullable(),
  company: z.string().max(120).nullable(),
  companyUrl: z.string().max(300).nullable(),
  avatarUrl: z.string().max(500).nullable(),
  sources: z.array(SourceSchema).max(10),
});

export async function GET(request: NextRequest) {
  const session = await requireSession(request);
  if (isResponse(session)) return session;
  const profile = await getProfile(session.userId);
  return NextResponse.json({ email: session.email, profile });
}

/** Confirm (or correct) — the only write path. */
export async function PUT(request: NextRequest) {
  const session = await requireSession(request);
  if (isResponse(session)) return session;
  const parsed = Body.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "invalid profile" }, { status: 400 });
  const profile = await confirmProfile(session.userId, parsed.data);
  return NextResponse.json({ profile });
}

export async function DELETE(request: NextRequest) {
  const session = await requireSession(request);
  if (isResponse(session)) return session;
  await deleteProfile(session.userId);
  return NextResponse.json({ ok: true });
}
