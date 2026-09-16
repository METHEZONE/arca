/**
 * Authenticated access to source audio retained from ARCA Core uploads.
 *
 * GET ?sessionId=...&deviceId=...          -> ordered chunk manifest
 * GET ?sessionId=...&deviceId=...&seq=0    -> the original WAV chunk bytes
 */

import { NextRequest, NextResponse } from "next/server";

import { hardwareIngestToken } from "@/lib/config";
import { durableStoreConfigured } from "@/lib/persistence/kv";
import {
  hardwareStorageKey,
  listAudioChunks,
  readAudioChunk,
} from "@/lib/hardware/audio-store";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const SESSION_ID_RE = /^[A-Za-z0-9_.-]+$/;

export async function GET(request: NextRequest) {
  const authFailure = authenticate(request);
  if (authFailure) return authFailure;

  const sessionId = request.nextUrl.searchParams.get("sessionId")?.trim() ?? "";
  const deviceId = request.nextUrl.searchParams.get("deviceId")?.trim() || undefined;
  if (!sessionId || sessionId.length > 96 || !SESSION_ID_RE.test(sessionId)) {
    return NextResponse.json({ error: "A valid sessionId is required." }, { status: 400 });
  }
  if (deviceId && deviceId.length > 96) {
    return NextResponse.json({ error: "deviceId is too long." }, { status: 400 });
  }

  const storageKey = hardwareStorageKey(sessionId, deviceId);
  const rawSeq = request.nextUrl.searchParams.get("seq");
  if (rawSeq === null) {
    const chunks = await listAudioChunks(storageKey);
    if (!chunks.length) {
      return NextResponse.json({ error: "Recording audio was not found." }, { status: 404 });
    }
    return NextResponse.json({
      ok: true,
      sessionId,
      deviceId,
      chunkCount: chunks.length,
      totalBytes: chunks.reduce((total, chunk) => total + chunk.size, 0),
      chunks,
    });
  }

  const seq = Number(rawSeq);
  if (!Number.isInteger(seq) || seq < 0 || seq > 4095) {
    return NextResponse.json({ error: "seq must be an integer from 0 to 4095." }, { status: 400 });
  }
  const chunk = await readAudioChunk(storageKey, seq);
  if (!chunk) {
    return NextResponse.json({ error: "Recording audio chunk was not found." }, { status: 404 });
  }

  // Copy onto an owned ArrayBuffer: Node's Buffer type exposes ArrayBufferLike,
  // while the Web Response constructor requires a concrete BodyInit.
  const body = Uint8Array.from(chunk.bytes).buffer;
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": chunk.contentType,
      "content-length": String(chunk.size),
      "content-disposition": `attachment; filename="${safeFileName(chunk.fileName)}"`,
      "etag": `"${chunk.sha256}"`,
      "cache-control": "private, max-age=31536000, immutable",
    },
  });
}

function authenticate(request: NextRequest): NextResponse | null {
  const requiredToken = hardwareIngestToken();
  if (!requiredToken && (process.env.NODE_ENV === "production" || process.env.VERCEL)) {
    return NextResponse.json(
      { error: "ARCA hardware audio is disabled until ARCA_INGEST_TOKEN is configured." },
      { status: 503 },
    );
  }
  if (!durableStoreConfigured() && (process.env.NODE_ENV === "production" || process.env.VERCEL)) {
    return NextResponse.json(
      { error: "ARCA hardware audio is disabled until DATABASE_URL is configured." },
      { status: 503 },
    );
  }
  if (!requiredToken) return null;
  const provided =
    request.headers.get("x-arca-device-token") ??
    request.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  return provided === requiredToken
    ? null
    : NextResponse.json({ error: "Invalid ARCA hardware token." }, { status: 401 });
}

function safeFileName(value: string): string {
  return value.replace(/[^A-Za-z0-9_.-]/g, "_").slice(0, 128) || "recording.wav";
}
