export const runtime = "nodejs";
export const dynamic = "force-dynamic";

import { NextResponse } from "next/server";
import { z } from "zod";
import { runDelegation } from "@/lib/delegate/engine";
import { resolveIdentity } from "@/lib/arca/identity";
import { checkQuota, quotaDenialResponseBody, resolveQuotaSubject } from "@/lib/arca/quota";
import { record } from "@/lib/arca/usage";

const BodySchema = z.object({
  command: z.string().trim().min(2).max(400),
});

/**
 * Streams delegation events as SSE: each `data:` line is one DelegationEvent.
 *
 * Metered identically to chat/transcribe (`resolveIdentity` + `checkQuota`):
 * this calls Claude too (see `lib/delegate/engine.ts`), so left unauthenticated
 * it was the same unmetered cost surface those routes were closed against.
 */
export async function POST(req: Request): Promise<Response> {
  const identity = await resolveIdentity(req);
  if (!identity) {
    return NextResponse.json({ error: "Unknown device." }, { status: 401 });
  }
  const deviceId = identity.kind === "device" ? identity.deviceId : identity.deviceId ?? undefined;
  const organizationId = identity.kind === "tenant" ? identity.organizationId : undefined;
  const userId = identity.kind === "tenant" ? identity.userId : undefined;

  const quotaSubject = await resolveQuotaSubject(identity);
  const denial = await checkQuota(quotaSubject);
  if (denial) {
    return NextResponse.json(quotaDenialResponseBody(denial), { status: 429 });
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "invalid json" }, { status: 400 });
  }

  const parsed = BodySchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json({ error: "invalid command" }, { status: 400 });
  }
  const { command } = parsed.data;

  const encoder = new TextEncoder();
  let ok = true;
  let errorMessage: string | undefined;
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        for await (const event of runDelegation(command)) {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
        }
      } catch (err: unknown) {
        ok = false;
        errorMessage = err instanceof Error ? err.message : "Delegation failed.";
        controller.enqueue(
          encoder.encode(`data: ${JSON.stringify({ type: "error", message: errorMessage })}\n\n`),
        );
      } finally {
        controller.close();
        await record({ deviceId, userId, organizationId, kind: "delegate", ok, error: errorMessage });
      }
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
    },
  });
}
