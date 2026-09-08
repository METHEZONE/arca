import { NextRequest, NextResponse } from "next/server";

import { deviceIdFromRequest } from "@/lib/arca/device";
import { deviceAccount } from "@/lib/arca/identity";
import { sessionFromRequest } from "@/lib/arca/session";
import { lifetimeStats } from "@/lib/arca/digest";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Whoami, for both halves of the link loop.
 *
 * The web onboarding flow calls this with the `arca_session` cookie set by the
 * auth callbacks, so a client component can tell which step it's on without
 * holding the session token itself.
 *
 * The Swift app calls it with the `x-arca-device` token it minted on first
 * launch and nothing else — it has no session and never will, since the account
 * is created in a browser. Answering from a device token is what lets the app
 * show "linked as you@example.com" instead of asking the user whether the thing
 * they did on the web worked. An unclaimed device is a normal answer
 * (`linked: false`), not an error: that's every install before onboarding.
 *
 * Both paths carry the "memory count" lifetime stats when there are any —
 * omitted entirely for a brand-new account with no usage yet.
 */
export async function GET(request: NextRequest) {
  const session = await sessionFromRequest(request);
  if (session) {
    const stats = await lifetimeStats(session.organizationId);
    return NextResponse.json({
      linked: true,
      userId: session.userId,
      organizationId: session.organizationId,
      email: session.email,
      ...(stats ? { stats } : {}),
    });
  }

  const deviceId = deviceIdFromRequest(request);
  if (!deviceId) {
    return NextResponse.json({ error: "Not signed in." }, { status: 401 });
  }

  const account = await deviceAccount(deviceId);
  if (!account) {
    return NextResponse.json({ linked: false, deviceId });
  }

  const stats = await lifetimeStats(account.organizationId);
  return NextResponse.json({
    linked: true,
    deviceId,
    userId: account.userId,
    organizationId: account.organizationId,
    email: account.email,
    plan: account.plan,
    ...(stats ? { stats } : {}),
  });
}
