import { NextRequest, NextResponse } from "next/server";

import { deviceIdFromRequest } from "@/lib/arca/device";
import { record } from "@/lib/arca/usage";
import { openAiKey } from "@/lib/config";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

/** OpenAI rejects uploads above 25MB; leave headroom for the multipart wrapper. */
const MAX_BYTES = 24 * 1024 * 1024;

/**
 * Transcription proxy.
 *
 * Recording is unlimited and free in the beta, so this route meters but never
 * refuses. It exists for two reasons: the OpenAI key stays server-side, and
 * every clip that passes through becomes a usage record — which is how "time
 * spent with ARCA", the traction metric, gets counted at all.
 *
 * Chunking and loudness normalisation stay on the device. Vercel's runtime has
 * no ffmpeg, and the app already has AVFoundation, so the client sends
 * already-prepared clips and this forwards one at a time.
 *
 * The default model is `whisper-1`, not the diarizing model. On far-field
 * Korean room audio, `gpt-4o-transcribe-diarize` measured 9% Hangul and looped
 * on hallucinated English; whisper-1 with a language hint measured 95–99% on
 * the same recordings. Diarization is not worth losing the transcript.
 */
export async function POST(request: NextRequest) {
  const deviceId = deviceIdFromRequest(request);
  if (!deviceId) {
    return NextResponse.json({ error: "Unknown device." }, { status: 401 });
  }

  const key = openAiKey();
  if (!key) {
    return NextResponse.json(
      { error: "ARCA Cloud has no transcription key configured." },
      { status: 503 },
    );
  }

  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return NextResponse.json({ error: "multipart/form-data body required." }, { status: 400 });
  }

  const file = form.get("file");
  if (!(file instanceof File) || file.size === 0) {
    return NextResponse.json({ error: "A non-empty `file` part is required." }, { status: 400 });
  }
  if (file.size > MAX_BYTES) {
    return NextResponse.json(
      { error: `Clip is ${(file.size / 1024 / 1024).toFixed(1)}MB — split it below 24MB.` },
      { status: 413 },
    );
  }

  const language = asString(form.get("language")) ?? "ko";
  const prompt = asString(form.get("prompt"));
  const audioSeconds = Number(asString(form.get("audioSeconds")) ?? "") || undefined;
  const model = process.env.ARCA_TRANSCRIBE_MODEL?.trim() || "whisper-1";

  const upstream = new FormData();
  upstream.set("file", file, file.name || "clip.mp3");
  upstream.set("model", model);
  upstream.set("response_format", "verbose_json");
  upstream.set("language", language);
  // Deterministic decoding — sampling is what produces whisper's repetition
  // loops on quiet passages.
  upstream.set("temperature", "0");
  if (prompt) upstream.set("prompt", prompt);

  try {
    const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}` },
      body: upstream,
    });

    if (!response.ok) {
      const detail = (await response.text()).slice(0, 300);
      await record({
        deviceId, kind: "transcribe", model, audioSeconds, ok: false,
        error: `HTTP ${response.status}: ${detail}`,
      });
      return NextResponse.json({ error: detail }, { status: 502 });
    }

    const payload = (await response.json()) as {
      text?: string;
      duration?: number;
      segments?: { text?: string; start?: number; end?: number }[];
    };

    const segments = (payload.segments ?? [])
      .map((s) => ({
        text: (s.text ?? "").trim(),
        start: s.start ?? 0,
        end: s.end ?? s.start ?? 0,
      }))
      .filter((s) => s.text.length > 0);

    await record({
      deviceId, kind: "transcribe", model,
      audioSeconds: audioSeconds ?? payload.duration,
      ok: true,
    });

    return NextResponse.json({
      text: payload.text ?? segments.map((s) => s.text).join(" "),
      duration: payload.duration,
      segments,
    });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    await record({
      deviceId, kind: "transcribe", model, audioSeconds, ok: false,
      error: message.slice(0, 200),
    });
    return NextResponse.json({ error: message }, { status: 502 });
  }
}

function asString(value: FormDataEntryValue | null): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}
