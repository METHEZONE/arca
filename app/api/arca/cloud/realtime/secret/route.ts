export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { authorizeInvite } from "@/lib/cloud";

const OPENAI_CLIENT_SECRETS = "https://api.openai.com/v1/realtime/client_secrets";

// Mints a short-lived OpenAI Realtime client secret for an invited tester's
// Watch. The app sends the session config (persona instructions, voice); the
// server adds THE ZONE's key and forwards. The secret expires in minutes and
// only opens a realtime session, so handing it to the device is fine.
export async function POST(req: Request): Promise<Response> {
  const auth = authorizeInvite(req);
  if (!auth) {
    return Response.json({ error: { message: "invalid or expired ARCA invite code" } }, { status: 401 });
  }
  const key = process.env.OPENAI_API_KEY?.trim();
  if (!key) {
    return Response.json({ error: { message: "ARCA Cloud has no OpenAI key configured" } }, { status: 500 });
  }

  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return Response.json({ error: { message: "invalid json" } }, { status: 400 });
  }
  const session = (body.session ?? {}) as Record<string, unknown>;
  const model = String(session.model ?? "gpt-realtime");
  if (!model.startsWith("gpt-realtime")) {
    return Response.json({ error: { message: "model not allowed" } }, { status: 400 });
  }
  const expiresAfter = (body.expires_after ?? {}) as Record<string, unknown>;
  const seconds = Math.min(Number(expiresAfter.seconds ?? 600), 900);

  const upstream = await fetch(OPENAI_CLIENT_SECRETS, {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "content-type": "application/json" },
    body: JSON.stringify({
      expires_after: { anchor: "created_at", seconds },
      session: { ...session, type: "realtime", model },
    }),
  });
  const text = await upstream.text();
  return new Response(text, {
    status: upstream.status,
    headers: { "content-type": upstream.headers.get("content-type") ?? "application/json", "cache-control": "no-store" },
  });
}
