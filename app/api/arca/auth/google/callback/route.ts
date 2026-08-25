import { NextRequest, NextResponse } from "next/server";

import { exchangeGoogleCode, linkOrCreateGoogleUser } from "@/lib/arca/google";
import { claimDevice } from "@/lib/arca/identity";
import { issueSession } from "@/lib/arca/session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const STATE_COOKIE = "arca_google_oauth";

/**
 * Step 2 of Google sign-in: Google redirects back here with `code` + `state`.
 * Verifies the state cookie set in step 1 (CSRF), exchanges the code, then
 * routes through the same `issueSession()` path the magic link callback
 * uses. Returns JSON rather than a redirect for the same reason that route
 * does — see its comment; both need the HTML hand-off Phase B builds.
 */
export async function GET(request: NextRequest) {
  const respond = (body: unknown, status: number) => {
    const res = NextResponse.json(body, { status });
    res.cookies.delete(STATE_COOKIE);
    return res;
  };

  const oauthError = request.nextUrl.searchParams.get("error");
  if (oauthError) {
    return respond({ error: `Google sign-in was cancelled (${oauthError}).` }, 400);
  }

  const code = request.nextUrl.searchParams.get("code");
  const state = request.nextUrl.searchParams.get("state");
  const cookie = request.cookies.get(STATE_COOKIE)?.value;
  if (!code || !state || !cookie) {
    return respond({ error: "Missing or expired sign-in state — please try again." }, 400);
  }

  const [expectedState, deviceId] = cookie.split(".");
  if (state !== expectedState) {
    return respond({ error: "Sign-in state mismatch — please try again." }, 400);
  }

  const redirectUri = `${request.nextUrl.origin}/api/arca/auth/google/callback`;

  let identity;
  try {
    identity = await exchangeGoogleCode(code, redirectUri);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Google sign-in failed.";
    return respond({ error: message }, 502);
  }

  const linked = await linkOrCreateGoogleUser(identity);

  if (deviceId) {
    await claimDevice(deviceId, linked.userId, linked.organizationId);
  }

  const sessionToken = await issueSession({
    userId: linked.userId,
    organizationId: linked.organizationId,
    email: linked.email,
  });

  return respond(
    {
      sessionToken,
      userId: linked.userId,
      organizationId: linked.organizationId,
      email: linked.email,
      claimedDeviceId: deviceId || undefined,
    },
    200,
  );
}
