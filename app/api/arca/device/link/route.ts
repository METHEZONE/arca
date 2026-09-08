import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";

import { verifyDeviceToken } from "@/lib/arca/device";
import { claimDevice } from "@/lib/arca/identity";
import { sessionFromRequest } from "@/lib/arca/session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BodySchema = z.object({ deviceToken: z.string().min(1) });

/**
 * Explicit device claim for an already-signed-in session — e.g. a second
 * device, or a device that existed before this one signed in. The magic-link
 * callback covers the common "sign up from the device you've been using"
 * case on its own; this covers the rest.
 *
 * Requires the real device token (not just an id) so a session can't claim a
 * device it was merely told the id of — the HMAC in the token is proof the
 * caller actually holds it.
 */
export async function POST(request: NextRequest) {
  const session = await sessionFromRequest(request);
  if (!session) {
    return NextResponse.json({ error: "Sign in required." }, { status: 401 });
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Body must be JSON." }, { status: 400 });
  }
  const parsed = BodySchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json({ error: "A `deviceToken` is required." }, { status: 400 });
  }

  const deviceId = verifyDeviceToken(parsed.data.deviceToken);
  if (!deviceId) {
    return NextResponse.json({ error: "Invalid device token." }, { status: 401 });
  }

  await claimDevice(deviceId, session.userId, session.organizationId);
  return NextResponse.json({ deviceId, claimed: true });
}
