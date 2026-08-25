/**
 * User sessions — the "exchange" `device.ts` describes: a device token proved
 * "this token was issued by us"; a session proves "this is the account that
 * signed in", and is what a device token gets traded for.
 *
 * Stateless HS256 JWTs (via `jose`), not a session table. Revocation before
 * expiry isn't possible with this design — acceptable for a small team's app
 * where the failure mode is "wait out a 30-day expiry", and it avoids a
 * sessions table + cleanup job that nothing here needs yet.
 */

import { SignJWT, jwtVerify } from "jose";

const SESSION_TTL_SECONDS = 60 * 60 * 24 * 30; // 30 days

export interface SessionClaims {
  userId: string;
  organizationId: string;
  email: string;
}

function secretKey(): Uint8Array {
  const s = process.env.ARCA_SESSION_SECRET?.trim();
  if (!s) {
    throw new Error(
      "ARCA_SESSION_SECRET is not set — the app cannot issue or verify sessions.",
    );
  }
  return new TextEncoder().encode(s);
}

export function hasSessionSecret(): boolean {
  return Boolean(process.env.ARCA_SESSION_SECRET?.trim());
}

export async function issueSession(claims: SessionClaims): Promise<string> {
  return new SignJWT({ ...claims })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime(`${SESSION_TTL_SECONDS}s`)
    .sign(secretKey());
}

/** Returns the session's claims, or null when the token is missing, expired,
 *  or not signed by us. Never throws — callers treat this like an auth check. */
export async function verifySession(
  token: string | null | undefined,
): Promise<SessionClaims | null> {
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, secretKey());
    const { userId, organizationId, email } = payload as Record<string, unknown>;
    if (typeof userId !== "string" || typeof organizationId !== "string" || typeof email !== "string") {
      return null;
    }
    return { userId, organizationId, email };
  } catch {
    return null;
  }
}

/** Pulls a session out of `Authorization: Bearer …`. Falls through (returns
 *  null) for a device token — those are handled separately by the caller. */
export async function sessionFromRequest(request: Request): Promise<SessionClaims | null> {
  const bearer = request.headers.get("authorization");
  if (!bearer?.toLowerCase().startsWith("bearer ")) return null;
  return verifySession(bearer.slice(7).trim());
}
