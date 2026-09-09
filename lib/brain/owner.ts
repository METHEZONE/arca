// Resolves the `owner` string every ARCA Brain row is scoped by.
// docs/ARCA-BRAIN.md §2 — device token first, then invite code, else 401.
// No `user:` promotion in v1: device/email owners stay as-is even once a
// device is later linked to an account.

import { eq } from "drizzle-orm";

import { deviceIdFromRequest } from "@/lib/arca/device";
import { authorizeInvite } from "@/lib/cloud";
import { sessionFromRequest } from "@/lib/arca/session";
import { db } from "@/lib/db/client";
import { devices } from "@/lib/db/schema";

export async function resolveOwner(req: Request): Promise<string | null> {
  // A signed-in tenant (session cookie / bearer, lib/arca/session.ts) is the
  // most specific identity, and the one every device of that user shares.
  const session = await sessionFromRequest(req).catch(() => null);
  if (session?.userId) return `user:${session.userId}`;

  // A device that has been linked to an account is that account.
  const deviceId = deviceIdFromRequest(req);
  if (deviceId) {
    const client = db();
    if (client) {
      const [row] = await client
        .select({ userId: devices.userId })
        .from(devices)
        .where(eq(devices.id, deviceId))
        .limit(1);
      if (row?.userId) return `user:${row.userId}`;
    }
  }

  // An invite code names a person, so it beats an unlinked device token:
  // otherwise minting a device identity would silently split one tester's
  // memory into a per-device silo until they linked the device.
  const invite = authorizeInvite(req);
  if (invite) return `email:${invite.email}`;

  if (deviceId) return `device:${deviceId}`;
  return null;
}
