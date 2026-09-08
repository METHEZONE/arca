import { NextResponse } from "next/server";

import { hasDeviceSecret, issueDeviceToken } from "@/lib/arca/device";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Mints a device token on first launch.
 *
 * Open by design: a fresh install has nothing to authenticate with, and the
 * token it receives only lets it spend against its own device id. The guard
 * against someone minting tokens in a loop is rate limiting at the edge, not a
 * credential the app doesn't have yet.
 */
export async function POST() {
  if (!hasDeviceSecret()) {
    return NextResponse.json(
      { error: "ARCA Cloud is not configured on this deployment." },
      { status: 503 },
    );
  }
  const { deviceId, token } = issueDeviceToken();
  return NextResponse.json({ deviceId, token });
}
