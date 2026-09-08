import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

/**
 * Device identity for the ARCA app, with no database behind it.
 *
 * The closed beta needs to know *which install* is calling so usage can be
 * attributed and abuse can be cut off — but standing up auth infrastructure
 * before there are users is backwards. So a token is the device id plus an
 * HMAC of it: the server can verify a token it has never seen by recomputing
 * the signature, which means identity works from the first deploy with no
 * table, no session store, and no login screen.
 *
 * What this deliberately is *not*: a login. It proves "this token was issued by
 * us", not "this is Minsung". Anyone who copies a token from a device can use
 * it. That is an acceptable trade for a beta among people you know, and it
 * upgrades cleanly — when real accounts arrive, a device token becomes
 * something you exchange for a session rather than something you trust on its
 * own.
 */

const VERSION = "d1";

function secret(): string {
  const s = process.env.ARCA_DEVICE_SECRET?.trim();
  if (!s) {
    throw new Error(
      "ARCA_DEVICE_SECRET is not set — the app cannot issue or verify device tokens.",
    );
  }
  return s;
}

export function hasDeviceSecret(): boolean {
  return Boolean(process.env.ARCA_DEVICE_SECRET?.trim());
}

function sign(deviceId: string): string {
  return createHmac("sha256", secret()).update(`${VERSION}:${deviceId}`).digest("base64url");
}

/** Mints a token for a fresh install. The device stores it and sends it back. */
export function issueDeviceToken(): { deviceId: string; token: string } {
  const deviceId = randomBytes(12).toString("base64url");
  return { deviceId, token: `${VERSION}.${deviceId}.${sign(deviceId)}` };
}

/**
 * Returns the device id a token attests to, or null when the token is missing,
 * malformed, or not signed by us. Comparison is constant-time so a caller can't
 * probe the signature byte by byte.
 */
export function verifyDeviceToken(token: string | null | undefined): string | null {
  if (!token) return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [version, deviceId, signature] = parts;
  if (version !== VERSION || !deviceId || !signature) return null;

  let expected: string;
  try {
    expected = sign(deviceId);
  } catch {
    return null;
  }
  const a = Buffer.from(signature);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return null;
  return timingSafeEqual(a, b) ? deviceId : null;
}

/** Pulls the token out of `Authorization: Bearer …` or the `x-arca-device` header. */
export function deviceIdFromRequest(request: Request): string | null {
  const bearer = request.headers.get("authorization");
  if (bearer?.toLowerCase().startsWith("bearer ")) {
    const id = verifyDeviceToken(bearer.slice(7).trim());
    if (id) return id;
  }
  return verifyDeviceToken(request.headers.get("x-arca-device"));
}
