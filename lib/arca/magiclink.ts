/**
 * Email magic links — the sign-in mechanism (Phase 2).
 *
 * Picked over Sign in with Apple for this first cut: it needs no Apple
 * Developer credentials this environment doesn't have (a private key,
 * Services ID, and JWKS verification setup), no native button/entitlement
 * work in the Swift app, and it's the one auth method that's fully testable
 * from the server alone. Sign in with Apple is a reasonable follow-up for a
 * companion app this tied to the Apple ecosystem — noted as an open product
 * decision in the final report.
 */

import { randomBytes, createHash } from "node:crypto";
import { and, eq, gt, isNull } from "drizzle-orm";

import { db } from "@/lib/db/client";
import { magicLinks, organizations, users } from "@/lib/db/schema";

const TOKEN_TTL_MS = 15 * 60 * 1000; // 15 minutes — short-lived, emailed link

function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("base64url");
}

/**
 * Creates a magic link token for `email`, storing only its hash. `deviceId`
 * is captured now (at request time, from the caller's own device token) so
 * the callback never has to trust a client-supplied device id — it just
 * claims whatever was recorded here.
 */
export async function createMagicLink(
  email: string,
  deviceId: string | null,
): Promise<string> {
  const database = db();
  if (!database) {
    throw new Error("DATABASE_URL is not set — sign-in is unavailable.");
  }
  const token = randomBytes(32).toString("base64url");
  await database.insert(magicLinks).values({
    email: email.toLowerCase().trim(),
    tokenHash: hashToken(token),
    deviceId: deviceId ?? undefined,
    expiresAt: new Date(Date.now() + TOKEN_TTL_MS),
  });
  return token;
}

export interface ConsumedMagicLink {
  userId: string;
  organizationId: string;
  email: string;
  deviceId: string | null;
}

/**
 * Verifies and single-use-consumes a token, creating the user (and a new
 * organization for them) on first sign-in. Returns null for a missing,
 * expired, or already-consumed token.
 */
export async function consumeMagicLink(token: string): Promise<ConsumedMagicLink | null> {
  const database = db();
  if (!database) return null;

  const tokenHash = hashToken(token);
  const [link] = await database
    .select()
    .from(magicLinks)
    .where(
      and(
        eq(magicLinks.tokenHash, tokenHash),
        isNull(magicLinks.consumedAt),
        gt(magicLinks.expiresAt, new Date()),
      ),
    )
    .limit(1);
  if (!link) return null;

  await database
    .update(magicLinks)
    .set({ consumedAt: new Date() })
    .where(eq(magicLinks.id, link.id));

  const [existing] = await database
    .select()
    .from(users)
    .where(eq(users.email, link.email))
    .limit(1);
  if (existing) {
    return {
      userId: existing.id,
      organizationId: existing.organizationId,
      email: existing.email,
      deviceId: link.deviceId,
    };
  }

  const [org] = await database
    .insert(organizations)
    .values({ name: link.email })
    .returning();
  const [user] = await database
    .insert(users)
    .values({ email: link.email, organizationId: org.id })
    .returning();
  return {
    userId: user.id,
    organizationId: org.id,
    email: user.email,
    deviceId: link.deviceId,
  };
}
