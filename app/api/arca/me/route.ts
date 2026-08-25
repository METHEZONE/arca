import { NextRequest, NextResponse } from "next/server";

import { sessionFromRequest } from "@/lib/arca/session";
import { lifetimeStats } from "@/lib/arca/digest";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Whoami for the web onboarding flow: reads the `arca_session` cookie set by
 * the auth callbacks so a client component can tell which step it's on
 * without holding the session token itself. Also carries the "memory count"
 * lifetime stats (Phase F) for a future dashboard — a brand-new sign-in has
 * nothing to show yet, so onboarding doesn't render this today.
 */
export async function GET(request: NextRequest) {
  const session = await sessionFromRequest(request);
  if (!session) {
    return NextResponse.json({ error: "Not signed in." }, { status: 401 });
  }
  const stats = await lifetimeStats(session.organizationId);
  return NextResponse.json({
    userId: session.userId,
    organizationId: session.organizationId,
    email: session.email,
    ...(stats ? { stats } : {}),
  });
}
