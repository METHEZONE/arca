import { NextRequest, NextResponse } from "next/server";

import { hardwareIngestToken } from "@/lib/config";
import { ingestRecording, IngestError } from "@/lib/ingest";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

export async function POST(request: NextRequest) {
  const requiredToken = hardwareIngestToken();
  if (requiredToken) {
    const provided =
      request.headers.get("x-arca-device-token") ??
      request.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
    if (provided !== requiredToken) {
      return NextResponse.json({ error: "Invalid ARCA hardware token." }, { status: 401 });
    }
  }

  let formData: FormData;
  try {
    formData = await request.formData();
  } catch {
    return NextResponse.json({ error: "multipart/form-data body is required." }, { status: 400 });
  }

  const file = formData.get("recording");
  if (!(file instanceof File)) {
    return NextResponse.json({ error: "The recording file is required." }, { status: 400 });
  }

  try {
    const memory = await ingestRecording(file, {
      source: "hardware",
      deviceId: textField(formData, "deviceId"),
      recordedAt: textField(formData, "recordedAt"),
      battery: textField(formData, "battery"),
    });
    return NextResponse.json({
      ok: true,
      memoryId: memory.id,
      title: memory.analysis.title,
      createdAt: memory.createdAt,
      integrations: memory.integrations,
    });
  } catch (cause) {
    if (cause instanceof IngestError) {
      const status = cause.message.includes("100MB")
        ? 413
        : cause.message.includes("Unsupported")
          ? 415
          : 400;
      return NextResponse.json({ error: cause.message }, { status });
    }
    console.error("[hardware-ingest]", cause);
    const detail = cause instanceof Error ? cause.message : "unknown ingest error";
    return NextResponse.json(
      {
        error: "ARCA could not process the hardware upload.",
        detail: detail.slice(0, 220),
      },
      { status: 500 },
    );
  }
}

function textField(formData: FormData, key: string): string | undefined {
  const value = formData.get(key);
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}
