/**
 * Google Sign-In — an alternative front door to the same accounts the magic
 * link (`magiclink.ts`) creates. Verified email is the join key: signing in
 * with Google attaches to an existing magic-link account with the matching
 * email, or creates a user+organization on first sign-in, same as
 * `consumeMagicLink` does.
 */

import { createRemoteJWKSet, jwtVerify } from "jose";
import { eq } from "drizzle-orm";

import { db } from "@/lib/db/client";
import { organizations, users } from "@/lib/db/schema";
import { googleOAuthClientId, googleOAuthClientSecret } from "@/lib/config";

const AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const JWKS = createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"));

export function hasGoogleOAuth(): boolean {
  return Boolean(googleOAuthClientId() && googleOAuthClientSecret());
}

export function buildGoogleAuthUrl(redirectUri: string, state: string): string {
  const clientId = googleOAuthClientId();
  if (!clientId) throw new Error("GOOGLE_OAUTH_CLIENT_ID is not set.");
  const params = new URLSearchParams({
    client_id: clientId,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: "openid email",
    state,
    prompt: "select_account",
  });
  return `${AUTH_URL}?${params.toString()}`;
}

interface GoogleIdentity {
  email: string;
  googleId: string;
}

/**
 * Exchanges an authorization code for tokens, then verifies the id_token
 * against Google's live JWKS — issuer, audience, and signature — rather than
 * trusting unsigned claims a caller could forge.
 */
export async function exchangeGoogleCode(
  code: string,
  redirectUri: string,
): Promise<GoogleIdentity> {
  const clientId = googleOAuthClientId();
  const clientSecret = googleOAuthClientSecret();
  if (!clientId || !clientSecret) {
    throw new Error("Google sign-in is not configured.");
  }

  const tokenRes = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: clientId,
      client_secret: clientSecret,
      redirect_uri: redirectUri,
      grant_type: "authorization_code",
    }),
  });
  if (!tokenRes.ok) {
    throw new Error(`Google token exchange failed (HTTP ${tokenRes.status}).`);
  }
  const { id_token: idToken } = (await tokenRes.json()) as { id_token?: string };
  if (!idToken) throw new Error("Google did not return an id_token.");

  const { payload } = await jwtVerify(idToken, JWKS, {
    issuer: ["https://accounts.google.com", "accounts.google.com"],
    audience: clientId,
  });

  const email = typeof payload.email === "string" ? payload.email : undefined;
  const emailVerified = payload.email_verified === true;
  const sub = typeof payload.sub === "string" ? payload.sub : undefined;
  if (!email || !emailVerified || !sub) {
    throw new Error("Google account has no verified email.");
  }
  return { email: email.toLowerCase().trim(), googleId: sub };
}

export interface LinkedGoogleUser {
  userId: string;
  organizationId: string;
  email: string;
}

/** Attaches to an existing account by verified email, or creates a fresh
 *  user+organization — mirrors `consumeMagicLink`'s account creation. */
export async function linkOrCreateGoogleUser(
  identity: GoogleIdentity,
): Promise<LinkedGoogleUser> {
  const database = db();
  if (!database) throw new Error("DATABASE_URL is not set — sign-in is unavailable.");

  const [existing] = await database
    .select()
    .from(users)
    .where(eq(users.email, identity.email))
    .limit(1);
  if (existing) {
    if (existing.googleId !== identity.googleId) {
      await database
        .update(users)
        .set({ googleId: identity.googleId })
        .where(eq(users.id, existing.id));
    }
    return {
      userId: existing.id,
      organizationId: existing.organizationId,
      email: existing.email,
    };
  }

  const [org] = await database
    .insert(organizations)
    .values({ name: identity.email })
    .returning();
  const [user] = await database
    .insert(users)
    .values({ email: identity.email, organizationId: org.id, googleId: identity.googleId })
    .returning();
  return { userId: user.id, organizationId: org.id, email: user.email };
}
