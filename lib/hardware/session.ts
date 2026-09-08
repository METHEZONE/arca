/**
 * Chunked hardware sessions.
 *
 * WHY THIS EXISTS
 *
 * ARCA Core records for hours. A 2-hour session is ~230 MB of 16 kHz mono WAV,
 * and Vercel Functions hard-cap a request body at 4.5 MB with no way to raise it
 * (https://vercel.com/docs/functions/limitations#request-body-size). The device
 * therefore uploads a long recording as a sequence of self-contained 100-second
 * WAV chunks that all carry the same `sessionId`. Each chunk is transcribed on
 * arrival, and the last one (`final=true`) stitches the parts into a single
 * Memory with one analysis pass.
 *
 * Side benefits of doing it this way rather than one giant upload:
 *   - each chunk stays well inside OpenAI's 25 MB per-request audio limit
 *   - a dropped connection costs one 100-second chunk, not the whole session
 *   - transcription runs while the device is still uploading, so a long
 *     recording is ready almost as soon as the last byte lands
 *
 * KNOWN LIMITATION: this uses the same on-disk store as memories, which on
 * Vercel resolves to /tmp and is per-instance and ephemeral. Chunks of one
 * session usually land on the same warm instance within seconds so it works in
 * practice, but for real durability point ARCA_DATA_DIR at a persistent volume,
 * or move both this and lib/secondbrain/store.ts onto Vercel Blob / Upstash.
 */

import { mkdir, readFile, writeFile, unlink, readdir } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

import { autoPushTargets, dataDir } from "@/lib/config";
import { analyze } from "@/lib/analysis";
import { transcribe } from "@/lib/transcription";
import { pushToTargets } from "@/lib/integrations";
import { newMemoryId, saveMemory, updateMemory } from "@/lib/secondbrain/store";
import { mailOwner } from "@/lib/hardware/notify";
import type { Memory, SpeakerSummary, Transcript, TranscriptSegment } from "@/lib/types";

const SESSION_ID_RE = /^[A-Za-z0-9_.-]+$/;
const MAX_CHUNKS = 4096; // 100 s each => ~113 hours, far past any battery

export type ChunkMeta = {
  sessionId: string;
  seq: number;
  totalChunks: number;
  offsetSec: number;
  final: boolean;
  deviceId?: string;
  recordedAt?: string;
  battery?: string;
};

type StoredChunk = {
  seq: number;
  offsetSec: number;
  transcript: Transcript;
};

type StoredSession = {
  sessionId: string;
  deviceId?: string;
  recordedAt?: string;
  battery?: string;
  totalChunks: number;
  updatedAt: string;
  chunks: StoredChunk[];
};

export class SessionError extends Error {}

/* ----------------------------------------------------------------- paths --- */

function baseDir(): string {
  // ponytail: on Vercel this is per-instance /tmp, so chunks of one session can
  // land on different lambdas and the final stitch misses them. Move
  // StoredSession to Postgres/Blob if long sessions come back incomplete.
  const configured = dataDir();
  if (process.env.VERCEL && !isAbsolute(configured)) return join("/tmp", configured);
  if (isAbsolute(configured)) return configured;
  return join(process.cwd(), configured);
}

function sessionsDir(): string {
  return join(baseDir(), "hardware-sessions");
}

function sessionPath(sessionId: string): string {
  return join(sessionsDir(), `${sessionId}.json`);
}

function assertSessionId(sessionId: string): void {
  if (!sessionId || !SESSION_ID_RE.test(sessionId) || sessionId.length > 96) {
    throw new SessionError(`Invalid sessionId: "${sessionId}"`);
  }
}

/* ---------------------------------------------------------------- storage -- */

async function readSession(sessionId: string): Promise<StoredSession | null> {
  try {
    const raw = await readFile(sessionPath(sessionId), "utf-8");
    return JSON.parse(raw) as StoredSession;
  } catch {
    return null;
  }
}

async function writeSession(session: StoredSession): Promise<void> {
  await mkdir(sessionsDir(), { recursive: true });
  await writeFile(sessionPath(session.sessionId), JSON.stringify(session), "utf-8");
}

async function dropSession(sessionId: string): Promise<void> {
  try {
    await unlink(sessionPath(sessionId));
  } catch {
    // already gone
  }
}

/** Remove session scratch files older than 24 h so /tmp cannot creep. */
export async function pruneStaleSessions(maxAgeHours = 24): Promise<number> {
  let removed = 0;
  try {
    const names = await readdir(sessionsDir());
    const cutoff = Date.now() - maxAgeHours * 3600_000;
    for (const name of names) {
      if (!name.endsWith(".json")) continue;
      const session = await readSession(name.replace(/\.json$/, ""));
      if (!session) continue;
      if (new Date(session.updatedAt).getTime() < cutoff) {
        await dropSession(session.sessionId);
        removed++;
      }
    }
  } catch {
    // no directory yet
  }
  return removed;
}

/* -------------------------------------------------------------- stitching -- */

/** Shift every segment of a chunk transcript into session-absolute time. */
function offsetSegments(transcript: Transcript, offsetSec: number): TranscriptSegment[] {
  const offsetMs = Math.round(offsetSec * 1000);
  return transcript.segments.map((segment) => ({
    ...segment,
    startMs: segment.startMs + offsetMs,
    endMs: segment.endMs + offsetMs,
  }));
}

/**
 * Diarization ids are only stable inside one request, so "speaker_0" in chunk 3
 * is not necessarily "speaker_0" in chunk 1. We do NOT pretend otherwise: each
 * chunk's speakers are namespaced by chunk, then collapsed back to friendly
 * labels only when a session is a single chunk (the common push-to-talk case).
 * Cross-chunk speaker identity needs voice embeddings, which is a separate job.
 */
function mergeTranscripts(chunks: StoredChunk[]): Transcript {
  const ordered = [...chunks].sort((a, b) => a.seq - b.seq);
  const singleChunk = ordered.length === 1;

  const segments: TranscriptSegment[] = [];
  const speakerAgg = new Map<string, SpeakerSummary>();
  let durationSec = 0;
  const warnings: string[] = [];
  let provider: Transcript["provider"] = "demo";
  let language = "en";

  for (const chunk of ordered) {
    const t = chunk.transcript;
    if (t.provider !== "demo") provider = t.provider;
    if (t.language) language = t.language;
    if (t.warning) warnings.push(`chunk ${chunk.seq}: ${t.warning}`);

    for (const segment of offsetSegments(t, chunk.offsetSec)) {
      const speaker = singleChunk ? segment.speaker : `c${chunk.seq}_${segment.speaker}`;
      const speakerLabel = singleChunk
        ? segment.speakerLabel
        : `${segment.speakerLabel} (part ${chunk.seq + 1})`;

      segments.push({ ...segment, speaker, speakerLabel });

      const talk = Math.max(0, (segment.endMs - segment.startMs) / 1000);
      const prev = speakerAgg.get(speaker);
      if (prev) {
        prev.segmentCount += 1;
        prev.talkTimeSec += talk;
      } else {
        speakerAgg.set(speaker, {
          speaker,
          speakerLabel,
          segmentCount: 1,
          talkTimeSec: talk,
        });
      }
    }

    durationSec = Math.max(durationSec, chunk.offsetSec + t.durationSec);
  }

  segments.sort((a, b) => a.startMs - b.startMs);

  const speakers = [...speakerAgg.values()].map((s) => ({
    ...s,
    talkTimeSec: Math.round(s.talkTimeSec),
  }));

  const fullText = segments
    .map((segment) => `${segment.speakerLabel}: ${segment.text}`)
    .join("\n");

  return {
    provider,
    language,
    durationSec: Math.round(durationSec),
    fullText,
    segments,
    speakerCount: speakers.length,
    speakers,
    warning: warnings.length ? warnings.join(" | ") : undefined,
  };
}

/* ----------------------------------------------------------------- public -- */

export type ChunkResult =
  | { status: "accepted"; sessionId: string; received: number; totalChunks: number }
  | { status: "complete"; sessionId: string; memory: Memory };

export async function ingestSessionChunk(file: File, meta: ChunkMeta): Promise<ChunkResult> {
  assertSessionId(meta.sessionId);
  if (!Number.isInteger(meta.seq) || meta.seq < 0 || meta.seq >= MAX_CHUNKS) {
    throw new SessionError(`Invalid seq: ${meta.seq}`);
  }
  if (file.size === 0) throw new SessionError("Empty chunk.");

  // Transcribe now, while the device is still sending the rest. By the time the
  // final chunk lands the session is essentially already done.
  let transcript: Transcript;
  try {
    transcript = await transcribe(file);
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause);
    transcript = {
      provider: "demo",
      language: "en",
      durationSec: 0,
      fullText: "",
      segments: [],
      speakerCount: 0,
      speakers: [],
      warning: `transcription failed: ${message}`,
    };
  }

  const existing = await readSession(meta.sessionId);
  const session: StoredSession = existing ?? {
    sessionId: meta.sessionId,
    deviceId: meta.deviceId,
    recordedAt: meta.recordedAt,
    battery: meta.battery,
    totalChunks: meta.totalChunks,
    updatedAt: new Date().toISOString(),
    chunks: [],
  };

  session.totalChunks = Math.max(session.totalChunks, meta.totalChunks);
  session.updatedAt = new Date().toISOString();
  session.deviceId ??= meta.deviceId;
  session.recordedAt ??= meta.recordedAt;
  session.battery = meta.battery ?? session.battery;

  // Idempotent: a retried chunk replaces its earlier copy instead of doubling.
  session.chunks = session.chunks.filter((c) => c.seq !== meta.seq);
  session.chunks.push({ seq: meta.seq, offsetSec: meta.offsetSec, transcript });

  if (!meta.final) {
    await writeSession(session);
    return {
      status: "accepted",
      sessionId: session.sessionId,
      received: session.chunks.length,
      totalChunks: session.totalChunks,
    };
  }

  // Final chunk: stitch, analyze once, save one memory.
  const merged = mergeTranscripts(session.chunks);
  const sourceFileName = `${session.sessionId}.wav`;
  const analysis = await analyze(merged, sourceFileName);
  const now = new Date().toISOString();

  const missing = session.totalChunks - session.chunks.length;
  const tags = [
    "hardware",
    session.deviceId ? `device:${session.deviceId}` : "",
    session.chunks.length > 1 ? `chunks:${session.chunks.length}` : "",
    missing > 0 ? `incomplete:${missing}` : "",
  ].filter(Boolean);

  const memory: Memory = {
    id: newMemoryId(),
    createdAt: session.recordedAt || now,
    updatedAt: now,
    sourceFileName,
    durationSec: merged.durationSec,
    speakerCount: merged.speakerCount,
    tags,
    transcript: merged,
    analysis,
    integrations: [],
    isDemo: merged.provider === "demo" || analysis.provider === "demo",
  };

  await saveMemory(memory);
  await dropSession(session.sessionId);

  // On Vercel that save lands in /tmp and is gone on the next cold start, so
  // the owner gets the result by mail. Best effort: the upload already succeeded.
  try {
    await mailOwner(memory);
  } catch (cause) {
    console.error("[hardware] owner mail failed:", cause instanceof Error ? cause.message : cause);
  }

  const targets = autoPushTargets();
  if (targets.length > 0) {
    try {
      const results = await pushToTargets(memory, targets);
      const updated = await updateMemory(memory.id, { integrations: results });
      if (updated) return { status: "complete", sessionId: session.sessionId, memory: updated };
      memory.integrations = results;
    } catch {
      // Auto-push is best effort; the memory is already saved.
    }
  }

  return { status: "complete", sessionId: session.sessionId, memory };
}
