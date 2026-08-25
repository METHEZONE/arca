import { NextRequest, NextResponse } from "next/server";

import { consumeMagicLink } from "@/lib/arca/magiclink";
import { claimDevice } from "@/lib/arca/identity";
import { issueSession } from "@/lib/arca/session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Step 2 of sign-in: the link the user clicked. Consumes the token,
 * creates the account on first sign-in, claims the device captured at
 * request time (if any), and returns a session.
 *
 * Returns JSON rather than a redirect: there's no web app to hand this off
 * to today, and wiring a universal link / custom URL scheme into the Swift
 * app to catch this is a client-side change out of scope here (left as a
 * TODO in the final report). Until that exists, this is reachable by a
 * device that already has the link (e.g. copy-pasted from the dev response
 * in `/api/arca/auth/request`, or a future in-app browser).
 */
export async function GET(request: NextRequest) {
  const token = request.nextUrl.searchParams.get("token");
  if (!token) {
    return NextResponse.json({ error: "Missing token." }, { status: 400 });
  }

  const consumed = await consumeMagicLink(token);
  if (!consumed) {
    return NextResponse.json(
      { error: "This link is invalid, expired, or already used." },
      { status: 400 },
    );
  }

  if (consumed.deviceId) {
    await claimDevice(consumed.deviceId, consumed.userId, consumed.organizationId);
  }

  const sessionToken = await issueSession({
    userId: consumed.userId,
    organizationId: consumed.organizationId,
    email: consumed.email,
  });

  return NextResponse.json({
    sessionToken,
    userId: consumed.userId,
    organizationId: consumed.organizationId,
    email: consumed.email,
    claimedDeviceId: consumed.deviceId,
  });
}
