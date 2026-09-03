export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { NextResponse } from "next/server";
import { z } from "zod";
import { adminTokenOk, downloadLink, signGrant } from "@/lib/beta";
import { inviteCode } from "@/lib/cloud";

const BodySchema = z.object({
  email: z.string().trim().email().max(200),
  days: z.number().int().min(1).max(90).optional(),
});

// Owner only: mint a signed download link for one tester.
export async function POST(req: Request): Promise<NextResponse> {
  const token = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? null;
  if (!adminTokenOk(token)) return NextResponse.json({ ok: false, error: "unauthorized" }, { status: 401 });
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ ok: false, error: "invalid json" }, { status: 400 });
  }
  const parsed = BodySchema.safeParse(body);
  if (!parsed.success) return NextResponse.json({ ok: false, error: "invalid email" }, { status: 400 });
  try {
    const grant = signGrant(parsed.data.email, parsed.data.days ?? 14);
    const cloud = signGrant(parsed.data.email, 90);
    const origin = new URL(req.url).origin;
    return NextResponse.json({
      ok: true,
      link: downloadLink(origin, grant),
      expiresAt: new Date(grant.exp * 1000).toISOString(),
      invite: inviteCode(cloud.email, cloud.exp, cloud.sig),
      inviteExpiresAt: new Date(cloud.exp * 1000).toISOString(),
    });
  } catch (e) {
    return NextResponse.json({ ok: false, error: (e as Error).message }, { status: 500 });
  }
}
