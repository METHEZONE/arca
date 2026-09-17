export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { signGrant } from "@/lib/beta";
import { FREE_TIER_DOMAIN, inviteCode } from "@/lib/cloud";

// Free tier: an ARCA install enrolls its device and gets a signed grant back,
// no application, no approval. Same grant format as an invite code, so every
// cloud route already understands it; the messages route pins these to Sonnet.
// Deliberately open — the people trying ARCA today are a handful, and the
// per-request caps (model allowlist, max_tokens) are the only brakes needed.
export async function POST(req: Request): Promise<Response> {
  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return Response.json({ error: { message: "invalid json" } }, { status: 400 });
  }
  const deviceId = String(body.deviceId ?? "").trim().toLowerCase();
  if (!/^[a-z0-9-]{8,64}$/.test(deviceId)) {
    return Response.json({ error: { message: "deviceId must be 8–64 chars of [a-z0-9-]" } }, { status: 400 });
  }
  const email = `dev-${deviceId}${FREE_TIER_DOMAIN}`;
  const grant = signGrant(email, 365);
  return Response.json(
    { code: inviteCode(grant.email, grant.exp, grant.sig), email: grant.email, expiresAt: grant.exp },
    { headers: { "cache-control": "no-store" } },
  );
}
