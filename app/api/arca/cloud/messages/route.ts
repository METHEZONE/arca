export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

import { authorizeInvite, composioEntity } from "@/lib/cloud";

const ANTHROPIC = "https://api.anthropic.com/v1/messages";
const MAX_TOKENS_CAP = 8192;

// Anthropic Messages passthrough (streaming or not) for invited testers.
// The body is forwarded as-is except for a max_tokens cap and a model
// allowlist; the response body is piped straight back.
export async function POST(req: Request): Promise<Response> {
  const auth = authorizeInvite(req);
  if (!auth) return Response.json({ type: "error", error: { type: "authentication_error", message: "invalid or expired ARCA invite code" } }, { status: 401 });
  const key = process.env.ANTHROPIC_API_KEY?.trim();
  if (!key) return Response.json({ type: "error", error: { type: "api_error", message: "ARCA Cloud has no model key configured" } }, { status: 500 });

  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return Response.json({ type: "error", error: { type: "invalid_request_error", message: "invalid json" } }, { status: 400 });
  }
  const model = String(body.model ?? "");
  if (!model.startsWith("claude-")) {
    return Response.json({ type: "error", error: { type: "invalid_request_error", message: "model not allowed" } }, { status: 400 });
  }
  body.max_tokens = Math.min(Number(body.max_tokens ?? 4096), MAX_TOKENS_CAP);
  // Anthropic wants an opaque id here, not an email — reuse the entity hash.
  body.metadata = { user_id: composioEntity(auth.email) };

  const headers: Record<string, string> = {
    "x-api-key": key,
    "anthropic-version": req.headers.get("anthropic-version") ?? "2023-06-01",
    "content-type": "application/json",
  };
  const beta = req.headers.get("anthropic-beta");
  if (beta) headers["anthropic-beta"] = beta;

  const upstream = await fetch(ANTHROPIC, { method: "POST", headers, body: JSON.stringify(body) });
  return new Response(upstream.body, {
    status: upstream.status,
    headers: {
      "content-type": upstream.headers.get("content-type") ?? "application/json",
      "cache-control": "no-store",
    },
  });
}
