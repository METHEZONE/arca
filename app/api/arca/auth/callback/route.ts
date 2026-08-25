import { NextRequest, NextResponse } from "next/server";

import { consumeMagicLink } from "@/lib/arca/magiclink";
import { claimDevice } from "@/lib/arca/identity";
import { issueSession, SESSION_COOKIE } from "@/lib/arca/session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const ONBOARDING = "/arca/onboarding";

/**
 * Step 2 of sign-in: the link the user clicked. Consumes the token, creates
 * the account on first sign-in, claims the device captured at request time
 * (if any), issues a session, and hands off into the web onboarding flow —
 * sets the session as an httpOnly cookie and redirects rather than returning
 * raw JSON, so a user clicking the emailed link lands somewhere real instead
 * of a blank JSON blob. The Swift app doesn't consume this route directly
 * (it signs in via the same magic-link token exchanged through its own UI,
 * not this browser redirect target).
 */
export async function GET(request: NextRequest) {
  const token = request.nextUrl.searchParams.get("token");
  if (!token) {
    return errorRedirect(request, "missing_token");
  }

  const consumed = await consumeMagicLink(token);
  if (!consumed) {
    return errorRedirect(request, "invalid_link");
  }

  if (consumed.deviceId) {
    await claimDevice(consumed.deviceId, consumed.userId, consumed.organizationId);
  }

  const sessionToken = await issueSession({
    userId: consumed.userId,
    organizationId: consumed.organizationId,
    email: consumed.email,
  });

  const res = NextResponse.redirect(new URL(`${ONBOARDING}?step=device`, request.nextUrl.origin));
  setSessionCookie(res, sessionToken);
  return res;
}

function errorRedirect(request: NextRequest, code: string) {
  return NextResponse.redirect(
    new URL(`${ONBOARDING}?step=signin&error=${code}`, request.nextUrl.origin),
  );
}

function setSessionCookie(res: NextResponse, token: string) {
  res.cookies.set(SESSION_COOKIE, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: 60 * 60 * 24 * 30,
  });
}
