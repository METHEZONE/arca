/**
 * POST /api/hardware/session/chunk
 *
 * Chunked upload endpoint for ARCA Core v1. A long recording arrives as a
 * sequence of self-contained 100-second WAV chunks sharing one sessionId; the
 * chunk with final=true stitches them into a single Memory.
 *
 * Exists because /api/hardware/ingest declares a 100 MB limit that Vercel can
 * never actually deliver: Vercel Functions cap the request body at 4.5 MB and it
 * is not configurable. See lib/hardware/session.ts for the full reasoning.
 *
 * multipart/form-data fields:
 *   recording    WAV chunk (required)
 *   sessionId    stable id for the whole recording, e.g. "20260804T193210"
 *   seq          0-based chunk index
 *   totalChunks  how many chunks this session has
 *   offsetSec    where this chunk starts inside the session
 *   final        "true" on the last chunk
 *   deviceId     e.g. "arca-core-v1-01"
 *   recordedAt   ISO8601 start time of the session
 *   battery      0.00 - 1.00
 *
 * Auth: same as /api/hardware/ingest - x-arca-device-token or Bearer.
 */

import { NextRequest, NextResponse } from "next/server";

import { hardwareIngestToken } from "@/lib/config";
import { ingestSessionChunk, SessionError, pruneStaleSessions } from "@/lib/hardware/session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

// One chunk is ~3.2 MB of audio. Anything meaningfully bigger would be rejected
// by the platform before it reached us, so fail fast with a useful message.
const MAX_CHUNK_BYTES = 4 * 1024 * 1024;

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
    return NextResponse.json(
      { error: "multipart/form-data body is required." },
      { status: 400 },
    );
  }

  const file = formData.get("recording");
  if (!(file instanceof File)) {
    return NextResponse.json({ error: "The recording chunk is required." }, { status: 400 });
  }
  if (file.size > MAX_CHUNK_BYTES) {
    return NextResponse.json(
      {
        error: `Chunk is ${(file.size / 1024 / 1024).toFixed(1)}MB. Keep chunks under 4MB — Vercel caps request bodies at 4.5MB.`,
      },
      { status: 413 },
    );
  }

  const sessionId = text(formData, "sessionId");
  if (!sessionId) {
    return NextResponse.json({ error: "sessionId is required." }, { status: 400 });
  }

  const seq = int(formData, "seq", 0);
  const totalChunks = Math.max(1, int(formData, "totalChunks", 1));
  const offsetSec = int(formData, "offsetSec", 0);
  const final = text(formData, "final") === "true";

  try {
    const result = await ingestSessionChunk(file, {
      sessionId,
      seq,
      totalChunks,
      offsetSec,
      final,
      deviceId: text(formData, "deviceId"),
      recordedAt: text(formData, "recordedAt"),
      battery: text(formData, "battery"),
    });

    if (result.status === "accepted") {
      return NextResponse.json({
        ok: true,
        status: "accepted",
        sessionId: result.sessionId,
        received: result.received,
        totalChunks: result.totalChunks,
      });
    }

    // Opportunistic cleanup; never blocks the response path on failure.
    void pruneStaleSessions().catch(() => {});

    return NextResponse.json({
      ok: true,
      status: "complete",
      sessionId: result.sessionId,
      memoryId: result.memory.id,
      title: result.memory.analysis.title,
      durationSec: result.memory.durationSec,
      createdAt: result.memory.createdAt,
      integrations: result.memory.integrations,
    });
  } catch (cause) {
    if (cause instanceof SessionError) {
      return NextResponse.json({ error: cause.message }, { status: 400 });
    }
    console.error("[hardware-session-chunk]", cause);
    const detail = cause instanceof Error ? cause.message : "unknown error";
    return NextResponse.json(
      { error: "ARCA could not process the chunk.", detail: detail.slice(0, 220) },
      { status: 500 },
    );
  }
}

function text(formData: FormData, key: string): string | undefined {
  const value = formData.get(key);
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function int(formData: FormData, key: string, fallback: number): number {
  const raw = text(formData, key);
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}
