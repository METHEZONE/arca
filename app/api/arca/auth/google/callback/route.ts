import { NextRequest, NextResponse } from "next/server";

import { exchangeGoogleCode, linkOrCreateGoogleUser } from "@/lib/arca/google";
import { claimDevice } from "@/lib/arca/identity";
import { issueSession, SESSION_COOKIE } from "@/lib/arca/session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const STATE_COOKIE = "arca_google_oauth";
const ONBOARDING = "/arca/onboarding";

/**
 * Step 2 of Google sign-in: Google redirects back here with `code` + `state`.
 * Verifies the state cookie set in step 1 (CSRF), exchanges the code, then
 * routes through the same `issueSession()` path the magic link callback
 * uses. Hands off into the web onboarding flow via an httpOnly session
 * cookie + redirect, same treatment as the magic-link callback, so the
 * browser never dead-ends on raw JSON.
 */
export async function GET(request: NextRequest) {
  const errorRedirect = (code: string) => {
    const res = NextResponse.redirect(
      new URL(`${ONBOARDING}?step=signin&error=${code}`, request.nextUrl.origin),
    );
    res.cookies.delete(STATE_COOKIE);
    return res;
  };

  const oauthError = request.nextUrl.searchParams.get("error");
  if (oauthError) {
    return errorRedirect("google_cancelled");
  }

  const code = request.nextUrl.searchParams.get("code");
  const state = request.nextUrl.searchParams.get("state");
  const cookie = request.cookies.get(STATE_COOKIE)?.value;
  if (!code || !state || !cookie) {
    return errorRedirect("google_state_expired");
  }

  const [expectedState, deviceId] = cookie.split(".");
  if (state !== expectedState) {
    return errorRedirect("google_state_mismatch");
  }

  const redirectUri = `${request.nextUrl.origin}/api/arca/auth/google/callback`;

  let identity;
  try {
    identity = await exchangeGoogleCode(code, redirectUri);
  } catch {
    return errorRedirect("google_exchange_failed");
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

  const res = NextResponse.redirect(new URL(`${ONBOARDING}?step=device`, request.nextUrl.origin));
  res.cookies.delete(STATE_COOKIE);
  res.cookies.set(SESSION_COOKIE, sessionToken, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: 60 * 60 * 24 * 30,
  });
  return res;
}
