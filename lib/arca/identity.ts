/**
 * Resolves "who is calling" for the metered routes (chat, transcribe),
 * across both credential types this app now accepts:
 *
 *  - A session Bearer token (Phase 2): a signed-in tenant. Usage is
 *    attributed to the organization and can be gated by its plan (Phase 4).
 *  - A device token (unchanged from the original device.ts model): an
 *    anonymous install with no account. Usage is attributed to the device id
 *    and treated as the implicit free tier — otherwise Phase 4's quota would
 *    be trivially bypassed by never signing in.
 *
 * A request can carry both (a claimed device that's also sending its device
 * token); the session wins, since it's the more specific identity.
 */

import { and, eq } from "drizzle-orm";

import { db } from "@/lib/db/client";
import { devices, organizations, users } from "@/lib/db/schema";
import { deviceIdFromRequest } from "@/lib/arca/device";
import type { Plan } from "@/lib/arca/plans";
import { sessionFromRequest } from "@/lib/arca/session";

export type Identity =
  | { kind: "tenant"; userId: string; organizationId: string; deviceId: string | null }
  | { kind: "device"; deviceId: string };

export async function resolveIdentity(request: Request): Promise<Identity | null> {
  const session = await sessionFromRequest(request);
  if (session) {
    return {
      kind: "tenant",
      userId: session.userId,
      organizationId: session.organizationId,
      deviceId: deviceIdFromRequest(request),
    };
  }
  const deviceId = deviceIdFromRequest(request);
  if (deviceId) return { kind: "device", deviceId };
  return null;
}

/**
 * The exchange `device.ts`'s comment describes: attaches a previously
 * anonymous device to an account. Idempotent — claiming an already-claimed
 * device just re-points it (covers a user signing into a second account,
 * which quietly re-attributes future usage rather than erroring).
 */
export async function claimDevice(
  deviceId: string,
  userId: string,
  organizationId: string,
): Promise<void> {
  const database = db();
  if (!database) return;
  await database
    .insert(devices)
    .values({ id: deviceId, userId, organizationId, claimedAt: new Date() })
    .onConflictDoUpdate({
      target: devices.id,
      set: { userId, organizationId, claimedAt: new Date() },
    });
}

export interface DeviceAccount {
  userId: string;
  organizationId: string;
  email: string;
  plan: Plan;
}

/**
 * The account a claimed device belongs to, or null while it's still anonymous.
 *
 * This is the read the Swift app needs and `isDeviceClaimedBy` can't serve: the
 * app holds a device token and nothing else — no session, no email, no idea
 * whether the browser half of onboarding ever completed. Answering "who am I
 * linked to?" from the token alone is what makes the link loop closeable from
 * the app's side.
 */
export async function deviceAccount(deviceId: string): Promise<DeviceAccount | null> {
  const database = db();
  if (!database) return null;
  try {
    const [row] = await database
      .select({
        userId: devices.userId,
        organizationId: devices.organizationId,
        email: users.email,
        plan: organizations.plan,
      })
      .from(devices)
      // Inner joins, so an unclaimed device (null user/org) returns no row at
      // all — which is exactly "not linked".
      .innerJoin(users, eq(users.id, devices.userId))
      .innerJoin(organizations, eq(organizations.id, devices.organizationId))
      .where(eq(devices.id, deviceId))
      .limit(1);
    if (!row?.userId || !row.organizationId) return null;
    return {
      userId: row.userId,
      organizationId: row.organizationId,
      email: row.email,
      plan: row.plan,
    };
  } catch (err) {
    // Same posture as the rest of this file: a DB blip reads as "not linked",
    // which the app renders as 연결 안 됨 rather than an error the user can't act on.
    console.error("arca.identity.device_account_failed", err instanceof Error ? err.message : err);
    return null;
  }
}

/** True once a device row exists and is claimed — used to short-circuit a
 *  device already tied to the caller's own account. */
export async function isDeviceClaimedBy(
  deviceId: string,
  organizationId: string,
): Promise<boolean> {
  const database = db();
  if (!database) return false;
  const [row] = await database
    .select()
    .from(devices)
    .where(and(eq(devices.id, deviceId), eq(devices.organizationId, organizationId)))
    .limit(1);
  return Boolean(row);
}
