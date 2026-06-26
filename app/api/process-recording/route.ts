import { NextRequest, NextResponse } from "next/server";

import { ingestRecording, ingestText, IngestError } from "@/lib/ingest";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

/**
 * The ARCA ingest pipeline:
 *   recording → diarized transcript → notes & action plan → second brain → auto-sync
 *
 * Every stage degrades gracefully: missing keys fall back to demo output, and a
 * failing transcription provider still yields a saved memory with a clear warning
 * rather than losing the recording.
 */
export async function POST(request: NextRequest) {
  try {
    const contentType = request.headers.get("content-type") ?? "";

    if (contentType.includes("application/json")) {
      const body = (await request.json()) as { text?: unknown };
      if (typeof body.text !== "string" || !body.text.trim()) {
        return NextResponse.json({ error: "The text field is required." }, { status: 400 });
      }

      const memory = await ingestText(body.text, { source: "dashboard" });
      return NextResponse.json(memory);
    }

    let formData: FormData;
    try {
      formData = await request.formData();
    } catch {
      return NextResponse.json(
        { error: "multipart/form-data body or JSON text is required." },
        { status: 400 },
      );
    }

    const file = formData.get("recording");
    if (!(file instanceof File)) {
      return NextResponse.json({ error: "The recording file is required." }, { status: 400 });
    }

    const memory = await ingestRecording(file, { source: "dashboard" });
    return NextResponse.json(memory);
  } catch (cause) {
    if (cause instanceof IngestError) {
      const status = cause.message.includes("100MB")
        ? 413
        : cause.message.includes("Unsupported")
          ? 415
          : 400;
      return NextResponse.json({ error: cause.message }, { status });
    }
    console.error("[process-recording]", cause);
    const detail = cause instanceof Error ? cause.message : "unknown ingest error";
    return NextResponse.json(
      {
        error: "ARCA could not process this recording. Check the file type or server logs.",
        detail: detail.slice(0, 220),
      },
      { status: 500 },
    );
  }
}
