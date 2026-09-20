import { NextRequest, NextResponse } from "next/server";

import { exchangeGoogleCode, linkOrCreateGoogleUser } from "@/lib/arca/google";
import { claimDevice } from "@/lib/arca/identity";
import { issueSession, setSessionCookie } from "@/lib/arca/session";
import { GOOGLE_HINT_COOKIE } from "@/lib/commitments/identity";
import { hasConfirmedProfile } from "@/lib/commitments/profile";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const STATE_COOKIE = "arca_google_oauth";
const ONBOARDING = "/arca/onboarding";
const APP_HOME = "/arca/app";
const APP_ONBOARDING = "/arca/app/onboarding";

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

  const [expectedState, deviceId, flow] = cookie.split(".");
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

  // A DB blip in linking/session issuance must still land the user somewhere
  // with a way forward, not a raw 500 — same guard as the magic-link callback.
  try {
    const linked = await linkOrCreateGoogleUser(identity);

    if (deviceId) {
      await claimDevice(deviceId, linked.userId, linked.organizationId);
    }

    const sessionToken = await issueSession({
      userId: linked.userId,
      organizationId: linked.organizationId,
      email: linked.email,
    });

    // Device-link flow (Mac/iPhone app) keeps its old destination; the web
    // app goes to identity onboarding until a profile is confirmed.
    let dest = flow === "device" ? `${ONBOARDING}?step=device` : APP_ONBOARDING;
    if (flow !== "device") {
      try {
        if (await hasConfirmedProfile(linked.userId)) dest = APP_HOME;
      } catch {
        /* fall through to onboarding */
      }
    }
    const res = NextResponse.redirect(new URL(dest, request.nextUrl.origin));
    res.cookies.delete(STATE_COOKIE);
    setSessionCookie(res, sessionToken);
    if (identity.name || identity.picture) {
      const hint = Buffer.from(JSON.stringify({ n: identity.name ?? null, p: identity.picture ?? null })).toString("base64url");
      res.cookies.set(GOOGLE_HINT_COOKIE, hint, {
        httpOnly: true,
        secure: process.env.VERCEL_ENV === "production",
        sameSite: "lax",
        maxAge: 15 * 60,
        path: "/",
      });
    }
    return res;
  } catch (err) {
    console.error("arca.auth.google_callback_failed", err instanceof Error ? err.message : err);
    return errorRedirect("server_error");
  }
}
