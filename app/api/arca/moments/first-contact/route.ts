import { NextRequest, NextResponse } from "next/server";
import Anthropic from "@anthropic-ai/sdk";

import { resolveIdentity } from "@/lib/arca/identity";
import { checkQuota, quotaDenialResponseBody, resolveQuotaSubject } from "@/lib/arca/quota";
import { anthropicKey, claudeModel } from "@/lib/config";
import {
  buildFirstContactMoment,
  pickHook,
  sanitizeSignals,
  FIRST_CONTACT_CAPS,
  type Lang,
} from "@/lib/moments/first-contact";
import { FIRST_CONTACT_SYSTEM_PROMPT, buildFirstContactUserMessage } from "@/lib/moments/prompt";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

interface FirstContactBody {
  name?: unknown;
  lang?: unknown;
  signals?: unknown;
  polish?: unknown;
}

/**
 * First Contact — the moment ARCA speaks first.
 *
 * The client (or a gatherer job) hands over what it found on the public web
 * about the signed-in user; this route turns those signals into the first
 * proactive message plus at most one *proposed* commitment. It runs with
 * zero keys: without an Anthropic key the deterministic renderer answers,
 * which is the demo path and the behavior floor. With a key and `polish:
 * true` the wording is refined by the model — but the hook selection, the
 * sources, and the proposed-not-authorized state all stay deterministic, so
 * a louder page or a helpful model can't smuggle in a fact or an action.
 */
export async function POST(request: NextRequest) {
  const identity = await resolveIdentity(request);
  if (!identity) {
    return NextResponse.json({ error: "Unknown device." }, { status: 401 });
  }

  const quotaSubject = await resolveQuotaSubject(identity);
  const denial = await checkQuota(quotaSubject);
  if (denial) {
    return NextResponse.json(quotaDenialResponseBody(denial), { status: 429 });
  }

  let body: FirstContactBody;
  try {
    body = (await request.json()) as FirstContactBody;
  } catch {
    return NextResponse.json({ error: "Body must be JSON." }, { status: 400 });
  }

  const name = typeof body.name === "string" ? body.name.slice(0, 80) : undefined;
  const lang: Lang = body.lang === "en" ? "en" : "ko";
  const { signals, errors } = sanitizeSignals(body.signals);

  const moment = buildFirstContactMoment({ name, signals, lang });
  let provider: "deterministic" | "claude" = "deterministic";

  const key = anthropicKey();
  const hook = pickHook(signals, new Date());
  if (key && body.polish === true && hook) {
    try {
      const client = new Anthropic({ apiKey: key });
      const response = await client.messages.create({
        model: claudeModel(),
        max_tokens: 700,
        system: FIRST_CONTACT_SYSTEM_PROMPT,
        messages: [
          { role: "user", content: buildFirstContactUserMessage({ name, hook, commitment: moment.commitment, lang }) },
        ],
      });
      const text = response.content
        .filter((block) => block.type === "text")
        .map((block) => block.text)
        .join("\n")
        .trim();
      // The polish is wording only. If the model dropped the evidence or
      // rambled past the cap, the deterministic message stands — provenance
      // is not negotiable for a first impression.
      const keepsEvidence = moment.sources.every((s) => text.includes(s.url)) ||
        (moment.commitment?.evidence.every((u) => text.includes(u)) ?? true);
      if (text.length > 0 && text.length <= FIRST_CONTACT_CAPS.message && keepsEvidence) {
        moment.message = text;
        provider = "claude";
      }
    } catch {
      // Fall through to the deterministic message — a first hello that
      // arrives beats a polished one that doesn't.
    }
  }

  return NextResponse.json({ moment, provider, dropped: errors.length });
}
