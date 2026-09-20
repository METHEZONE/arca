import { NextResponse } from "next/server";

import { sessionFromRequest, type SessionClaims } from "@/lib/arca/session";

/** Session-only guard for the commitment loop (no device tokens here — the
 *  loop is per-person and the web app is the only client). */
export async function requireSession(request: Request): Promise<SessionClaims | NextResponse> {
  const session = await sessionFromRequest(request);
  if (!session) return NextResponse.json({ error: "Not signed in." }, { status: 401 });
  return session;
}

export function isResponse(x: unknown): x is NextResponse {
  return x instanceof NextResponse;
}
