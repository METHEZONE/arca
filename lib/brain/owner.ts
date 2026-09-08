// Resolves the `owner` string every ARCA Brain row is scoped by.
// docs/ARCA-BRAIN.md §2 — device token first, then invite code, else 401.
// No `user:` promotion in v1: device/email owners stay as-is even once a
// device is later linked to an account.

import { eq } from "drizzle-orm";

import { deviceIdFromRequest } from "@/lib/arca/device";
import { authorizeInvite } from "@/lib/cloud";
import { db } from "@/lib/db/client";
import { devices } from "@/lib/db/schema";

export async function resolveOwner(req: Request): Promise<string | null> {
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
    return `device:${deviceId}`;
  }

  const invite = authorizeInvite(req);
  if (invite) return `email:${invite.email}`;

  return null;
}
