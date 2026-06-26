import { NextRequest, NextResponse } from "next/server";

import { slackSigningSecret } from "@/lib/config";
import { handleSlackEvent } from "@/lib/slack-agent/agent";
import { verifySlackSignature } from "@/lib/slack-agent/signing";
import type { SlackEventEnvelope } from "@/lib/slack-agent/types";

export async function GET() {
  return NextResponse.json({
    ok: true,
    service: "the-zone-bio-slack-agent",
    mode: "events-api",
  });
}

export async function POST(request: NextRequest) {
  const body = await request.text();
  const signingSecret = slackSigningSecret();

  if (signingSecret) {
    const verified = verifySlackSignature({
      body,
      signingSecret,
      timestamp: request.headers.get("x-slack-request-timestamp"),
      signature: request.headers.get("x-slack-signature"),
    });

    if (!verified) {
      return NextResponse.json({ ok: false, error: "invalid_slack_signature" }, { status: 401 });
    }
  }

  const envelope = JSON.parse(body) as SlackEventEnvelope;

  if (envelope.type === "url_verification") {
    return NextResponse.json({ challenge: envelope.challenge });
  }

  if (envelope.type !== "event_callback") {
    return NextResponse.json({ ok: true, ignored: envelope.type });
  }

  const result = await handleSlackEvent(envelope);
  return NextResponse.json({ ok: true, ...result });
}
