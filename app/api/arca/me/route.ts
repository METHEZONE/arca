import { NextRequest, NextResponse } from "next/server";

import { sessionFromRequest } from "@/lib/arca/session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Whoami for the web onboarding flow: reads the `arca_session` cookie set by
 * the auth callbacks so a client component can tell which step it's on
 * without holding the session token itself.
 */
export async function GET(request: NextRequest) {
  const session = await sessionFromRequest(request);
  if (!session) {
    return NextResponse.json({ error: "Not signed in." }, { status: 401 });
  }
  return NextResponse.json({
    userId: session.userId,
    organizationId: session.organizationId,
    email: session.email,
  });
}
