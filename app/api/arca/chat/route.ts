import { NextRequest, NextResponse } from "next/server";
import Anthropic from "@anthropic-ai/sdk";

import { deviceIdFromRequest } from "@/lib/arca/device";
import { record } from "@/lib/arca/usage";
import { anthropicKey } from "@/lib/config";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 120;

/** Cap per reply so one runaway request can't drain the beta budget. */
const MAX_TOKENS = 2048;
/** Cap on conversation length — beyond this the client should compact. */
const MAX_MESSAGES = 60;

interface ChatBody {
  messages?: unknown;
  system?: unknown;
  model?: unknown;
}

/**
 * Chat proxy.
 *
 * The point is key custody: the Anthropic key lives here and never ships inside
 * the app, where anyone could pull it out of the bundle and spend against it.
 * The app sends a conversation and a device token; it never sees a provider
 * credential.
 *
 * The model is chosen server-side on purpose. A client that names its own model
 * could ask for the most expensive one available, and being able to retune cost
 * across the whole beta by editing one line here — rather than shipping an
 * app update — is worth more than client flexibility.
 */
export async function POST(request: NextRequest) {
  const deviceId = deviceIdFromRequest(request);
  if (!deviceId) {
    return NextResponse.json({ error: "Unknown device." }, { status: 401 });
  }

  const key = anthropicKey();
  if (!key) {
    return NextResponse.json(
      { error: "ARCA Cloud has no analysis key configured." },
      { status: 503 },
    );
  }

  let body: ChatBody;
  try {
    body = (await request.json()) as ChatBody;
  } catch {
    return NextResponse.json({ error: "Body must be JSON." }, { status: 400 });
  }

  const messages = normalizeMessages(body.messages);
  if (!messages) {
    return NextResponse.json(
      { error: "messages must be a non-empty array of {role, content} with text content." },
      { status: 400 },
    );
  }
  const system = typeof body.system === "string" ? body.system : undefined;
  const model = process.env.ARCA_CHAT_MODEL?.trim() || "claude-sonnet-5";

  try {
    const client = new Anthropic({ apiKey: key });
    const response = await client.messages.create({
      model,
      max_tokens: MAX_TOKENS,
      ...(system ? { system } : {}),
      messages,
    });

    const text = response.content
      .filter((block): block is Anthropic.TextBlock => block.type === "text")
      .map((block) => block.text)
      .join("");

    await record({
      deviceId,
      kind: "chat",
      model: response.model,
      inputTokens: response.usage.input_tokens,
      outputTokens: response.usage.output_tokens,
      ok: true,
    });

    return NextResponse.json({
      text,
      model: response.model,
      stopReason: response.stop_reason,
      usage: {
        inputTokens: response.usage.input_tokens,
        outputTokens: response.usage.output_tokens,
      },
    });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    await record({ deviceId, kind: "chat", model, ok: false, error: message.slice(0, 200) });
    // Provider errors are relayed as 502 — the request was fine, the upstream
    // wasn't, and the app should retry rather than treat it as its own bug.
    return NextResponse.json({ error: message }, { status: 502 });
  }
}

/**
 * Accepts only the shape the app actually sends: alternating text turns. Images
 * and tool blocks are rejected rather than forwarded, so the proxy's cost
 * surface stays predictable.
 */
function normalizeMessages(input: unknown): Anthropic.MessageParam[] | null {
  if (!Array.isArray(input) || input.length === 0 || input.length > MAX_MESSAGES) return null;
  const out: Anthropic.MessageParam[] = [];
  for (const raw of input) {
    if (typeof raw !== "object" || raw === null) return null;
    const { role, content } = raw as { role?: unknown; content?: unknown };
    if (role !== "user" && role !== "assistant") return null;
    if (typeof content !== "string" || content.trim().length === 0) return null;
    out.push({ role, content });
  }
  // Anthropic requires the conversation to open on a user turn.
  if (out[0].role !== "user") return null;
  return out;
}
