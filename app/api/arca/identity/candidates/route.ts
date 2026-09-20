import { NextRequest, NextResponse } from "next/server";

import { isResponse, requireSession } from "@/lib/commitments/auth";
import { GOOGLE_HINT_COOKIE, buildCandidates, readGoogleHint } from "@/lib/commitments/identity";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Identity candidates from public signals only. Nothing is stored. */
export async function GET(request: NextRequest) {
  const session = await requireSession(request);
  if (isResponse(session)) return session;
  const hint = readGoogleHint(request.cookies.get(GOOGLE_HINT_COOKIE)?.value);
  const result = await buildCandidates({ email: session.email, googleName: hint.name, googlePicture: hint.picture });
  return NextResponse.json({ email: session.email, ...result });
}
