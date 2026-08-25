import { randomBytes } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";

import { buildGoogleAuthUrl, hasGoogleOAuth } from "@/lib/arca/google";
import { verifyDeviceToken } from "@/lib/arca/device";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const STATE_COOKIE = "arca_google_oauth";
const STATE_TTL_SECONDS = 5 * 60;

/**
 * Step 1 of Google sign-in: redirect to Google's consent screen.
 *
 * Mirrors `auth/request`'s magic link: an optional `device` token is
 * verified now (not trusted later off a client-supplied value) and carried
 * through the round trip in an httpOnly cookie alongside a CSRF nonce, so
 * the callback claims whatever device was recorded here rather than
 * whatever a redirect's query string claims.
 */
export async function GET(request: NextRequest) {
  if (!hasGoogleOAuth()) {
    return NextResponse.json({ error: "Google sign-in is not configured." }, { status: 503 });
  }

  const deviceId = verifyDeviceToken(request.nextUrl.searchParams.get("device"));
  const state = randomBytes(24).toString("base64url");
  const redirectUri = `${request.nextUrl.origin}/api/arca/auth/google/callback`;

  const response = NextResponse.redirect(buildGoogleAuthUrl(redirectUri, state));
  response.cookies.set(STATE_COOKIE, `${state}.${deviceId ?? ""}`, {
    httpOnly: true,
    secure: process.env.VERCEL_ENV === "production",
    sameSite: "lax",
    maxAge: STATE_TTL_SECONDS,
    path: "/",
  });
  return response;
}
