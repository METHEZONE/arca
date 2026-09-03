export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 120;

import { authorizeInvite, composioEntity } from "@/lib/cloud";

const COMPOSIO = "https://backend.composio.dev/api/v3";

// Composio passthrough scoped to the caller's identity: every user_id the app
// sends is replaced with the entity derived from the invite email, so one
// tester can never see or act through another's connected accounts.
async function forward(req: Request, path: string[]): Promise<Response> {
  const auth = authorizeInvite(req);
  if (!auth) return Response.json({ error: "invalid or expired ARCA invite code" }, { status: 401 });
  const key = process.env.COMPOSIO_API_KEY?.trim();
  if (!key) return Response.json({ error: "ARCA Cloud has no connector key configured" }, { status: 500 });
  const entity = composioEntity(auth.email);

  const incoming = new URL(req.url);
  const target = new URL(`${COMPOSIO}/${path.join("/")}`);
  incoming.searchParams.forEach((v, k) => {
    target.searchParams.set(k, k === "user_ids" || k === "user_id" ? entity : v);
  });

  const init: RequestInit = { method: req.method, headers: { "x-api-key": key } };
  if (req.method !== "GET" && req.method !== "HEAD") {
    const text = await req.text();
    let out = text;
    try {
      const json = JSON.parse(text) as Record<string, unknown>;
      if ("user_id" in json) json.user_id = entity;
      if ("user_ids" in json) json.user_ids = [entity];
      out = JSON.stringify(json);
    } catch {
      /* not json: forward as-is */
    }
    init.body = out;
    (init.headers as Record<string, string>)["content-type"] = req.headers.get("content-type") ?? "application/json";
  }
  const upstream = await fetch(target, init);
  return new Response(upstream.body, {
    status: upstream.status,
    headers: { "content-type": upstream.headers.get("content-type") ?? "application/json", "cache-control": "no-store" },
  });
}

type Ctx = { params: Promise<{ path: string[] }> };
export async function GET(req: Request, ctx: Ctx) { return forward(req, (await ctx.params).path); }
export async function POST(req: Request, ctx: Ctx) { return forward(req, (await ctx.params).path); }
export async function PATCH(req: Request, ctx: Ctx) { return forward(req, (await ctx.params).path); }
export async function DELETE(req: Request, ctx: Ctx) { return forward(req, (await ctx.params).path); }
