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
 * When DATABASE_URL is configured, every chunk and completion receipt is stored
 * in Postgres. A Vercel retry or cold start can therefore resume safely on a
 * different function instance. Local development keeps the zero-setup JSON
 * fallback under ARCA_DATA_DIR.
 */

import { mkdir, readFile, writeFile, unlink, readdir } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

import { autoPushTargets, dataDir } from "@/lib/config";
import { analyze } from "@/lib/analysis";
import { transcribe } from "@/lib/transcription";
import { pushToTargets } from "@/lib/integrations";
import { saveMemory, updateMemory } from "@/lib/secondbrain/store";
import { mailOwner } from "@/lib/hardware/notify";
import {
  AudioChunkConflictError,
  hardwareStorageKey,
  storeAudioChunk,
} from "@/lib/hardware/audio-store";
import {
  durableStoreConfigured,
  kvClaim,
  kvDelete,
  kvDeletePrefix,
  kvGet,
  kvList,
  kvPut,
} from "@/lib/persistence/kv";
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

type DurableChunk = StoredChunk & {
  storageKey: string;
  sessionId: string;
  totalChunks: number;
  deviceId?: string;
  recordedAt?: string;
  battery?: string;
  updatedAt: string;
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

export class IncompleteSessionError extends SessionError {
  constructor(
    public readonly received: number,
    public readonly totalChunks: number,
    public readonly missing: number[],
  ) {
    super(`Session is incomplete: received ${received}/${totalChunks} chunks; missing ${missing.join(", ")}.`);
  }
}

const CHUNK_NAMESPACE = "hardware-chunk";
const RECEIPT_NAMESPACE = "hardware-receipt";
const FINALIZE_NAMESPACE = "hardware-finalize";
const localFinalizationClaims = new Set<string>();

/* ----------------------------------------------------------------- paths --- */

function baseDir(): string {
  const configured = dataDir();
  if (process.env.VERCEL && !isAbsolute(configured)) return join("/tmp", configured);
  if (isAbsolute(configured)) return configured;
  return join(/* turbopackIgnore: true */ process.cwd(), configured);
}

function sessionsDir(): string {
  return join(baseDir(), "hardware-sessions");
}

function receiptsDir(): string {
  return join(baseDir(), "hardware-receipts");
}

function sessionPath(storageKey: string): string {
  return join(sessionsDir(), `${storageKey}.json`);
}

function receiptPath(storageKey: string): string {
  return join(receiptsDir(), `${storageKey}.json`);
}

function sessionStorageKey(sessionId: string, deviceId?: string): string {
  return hardwareStorageKey(sessionId, deviceId);
}

function chunkKey(storageKey: string, seq: number): string {
  return `${storageKey}:${seq.toString().padStart(4, "0")}`;
}

function assertSessionId(sessionId: string): void {
  if (!sessionId || !SESSION_ID_RE.test(sessionId) || sessionId.length > 96) {
    throw new SessionError(`Invalid sessionId: "${sessionId}"`);
  }
}

function isNotFound(cause: unknown): boolean {
  return (cause as NodeJS.ErrnoException).code === "ENOENT";
}

/* ---------------------------------------------------------------- storage -- */

async function readSession(storageKey: string): Promise<StoredSession | null> {
  if (durableStoreConfigured()) {
    const rows = await kvList<DurableChunk>(CHUNK_NAMESPACE, `${storageKey}:`);
    if (!rows.length) return null;
    const chunks = rows.map(({ value }) => value).sort((a, b) => a.seq - b.seq);
    const newest = [...chunks].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))[0];
    const first = chunks[0];
    return {
      sessionId: first.sessionId,
      deviceId: first.deviceId ?? newest.deviceId,
      recordedAt: first.recordedAt ?? newest.recordedAt,
      battery: newest.battery ?? first.battery,
      totalChunks: Math.max(...chunks.map((chunk) => chunk.totalChunks)),
      updatedAt: newest.updatedAt,
      chunks: chunks.map(({ seq, offsetSec, transcript }) => ({ seq, offsetSec, transcript })),
    };
  }
  try {
    const raw = await readFile(sessionPath(storageKey), "utf-8");
    return JSON.parse(raw) as StoredSession;
  } catch (cause) {
    if (isNotFound(cause)) return null;
    throw cause;
  }
}

async function writeSession(storageKey: string, session: StoredSession): Promise<void> {
  await mkdir(sessionsDir(), { recursive: true });
  await writeFile(sessionPath(storageKey), JSON.stringify(session), "utf-8");
}

async function storeChunk(meta: ChunkMeta, transcript: Transcript): Promise<StoredSession> {
  const storageKey = sessionStorageKey(meta.sessionId, meta.deviceId);
  if (durableStoreConfigured()) {
    const updatedAt = new Date().toISOString();
    const chunk: DurableChunk = {
      storageKey,
      sessionId: meta.sessionId,
      seq: meta.seq,
      offsetSec: meta.offsetSec,
      transcript,
      totalChunks: meta.totalChunks,
      deviceId: meta.deviceId,
      recordedAt: meta.recordedAt,
      battery: meta.battery,
      updatedAt,
    };
    await kvPut(CHUNK_NAMESPACE, chunkKey(storageKey, meta.seq), chunk);
    const stored = await readSession(storageKey);
    if (!stored) throw new Error("Stored hardware chunk could not be read back.");
    return stored;
  }

  const existing = await readSession(storageKey);
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
  session.chunks = session.chunks.filter((chunk) => chunk.seq !== meta.seq);
  session.chunks.push({ seq: meta.seq, offsetSec: meta.offsetSec, transcript });
  await writeSession(storageKey, session);
  return session;
}

async function dropSession(storageKey: string): Promise<void> {
  if (durableStoreConfigured()) {
    await kvDeletePrefix(CHUNK_NAMESPACE, `${storageKey}:`);
    return;
  }
  try {
    await unlink(sessionPath(storageKey));
  } catch (cause) {
    if (!isNotFound(cause)) throw cause;
  }
}

async function readReceipt(storageKey: string): Promise<Memory | null> {
  if (durableStoreConfigured()) {
    return kvGet<Memory>(RECEIPT_NAMESPACE, storageKey);
  }
  try {
    return JSON.parse(await readFile(receiptPath(storageKey), "utf-8")) as Memory;
  } catch (cause) {
    if (isNotFound(cause)) return null;
    throw cause;
  }
}

async function writeReceipt(storageKey: string, memory: Memory): Promise<void> {
  if (durableStoreConfigured()) {
    await kvPut(RECEIPT_NAMESPACE, storageKey, memory);
    return;
  }
  await mkdir(receiptsDir(), { recursive: true });
  await writeFile(receiptPath(storageKey), JSON.stringify(memory), "utf-8");
}

async function claimFinalization(storageKey: string): Promise<boolean> {
  if (durableStoreConfigured()) {
    return kvClaim(FINALIZE_NAMESPACE, storageKey, { startedAt: new Date().toISOString() });
  }
  if (localFinalizationClaims.has(storageKey)) return false;
  localFinalizationClaims.add(storageKey);
  return true;
}

async function releaseFinalization(storageKey: string): Promise<void> {
  if (durableStoreConfigured()) {
    await kvDelete(FINALIZE_NAMESPACE, storageKey);
    return;
  }
  localFinalizationClaims.delete(storageKey);
}

async function waitForReceipt(storageKey: string, timeoutMs = 300_000): Promise<Memory> {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const receipt = await readReceipt(storageKey);
    if (receipt) return receipt;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("Another request is still finalizing this hardware session.");
}

/** Remove session scratch files older than 24 h so /tmp cannot creep. */
export async function pruneStaleSessions(maxAgeHours = 24): Promise<number> {
  let removed = 0;
  const cutoff = Date.now() - maxAgeHours * 3600_000;
  if (durableStoreConfigured()) {
    const chunks = await kvList<DurableChunk>(CHUNK_NAMESPACE);
    const newestBySession = new Map<string, number>();
    for (const { value } of chunks) {
      const updated = new Date(value.updatedAt).getTime();
      const storageKey = value.storageKey ?? sessionStorageKey(value.sessionId, value.deviceId);
      newestBySession.set(storageKey, Math.max(newestBySession.get(storageKey) ?? 0, updated));
    }
    for (const [storageKey, updated] of newestBySession) {
      if (updated < cutoff) {
        await dropSession(storageKey);
        removed++;
      }
    }
    return removed;
  }

  try {
    const names = await readdir(sessionsDir());
    for (const name of names) {
      if (!name.endsWith(".json")) continue;
      const storageKey = name.replace(/\.json$/, "");
      const session = await readSession(storageKey);
      if (!session) continue;
      if (new Date(session.updatedAt).getTime() < cutoff) {
        await dropSession(storageKey);
        removed++;
      }
    }
  } catch (cause) {
    if (!isNotFound(cause)) throw cause;
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
  | { status: "complete"; sessionId: string; memory: Memory; needsDelivery: boolean };

function hardwareMemoryId(sessionId: string, deviceId?: string): string {
  const digest = sessionStorageKey(sessionId, deviceId).slice(0, 24);
  return `hw-${digest}`;
}

export async function deliverCompletedMemory(memory: Memory): Promise<void> {
  const targets = autoPushTargets();
  if (targets.length > 0) {
    try {
      const results = await pushToTargets(memory, targets);
      await updateMemory(memory.id, { integrations: results });
    } catch (cause) {
      console.error("[hardware] auto-push failed:", cause instanceof Error ? cause.message : cause);
    }
  }

  try {
    await mailOwner(memory);
  } catch (cause) {
    console.error("[hardware] owner mail failed:", cause instanceof Error ? cause.message : cause);
  }
}

export async function ingestSessionChunk(file: File, meta: ChunkMeta): Promise<ChunkResult> {
  assertSessionId(meta.sessionId);
  const storageKey = sessionStorageKey(meta.sessionId, meta.deviceId);
  if (!Number.isInteger(meta.totalChunks) || meta.totalChunks < 1 || meta.totalChunks > MAX_CHUNKS) {
    throw new SessionError(`Invalid totalChunks: ${meta.totalChunks}`);
  }
  if (!Number.isInteger(meta.seq) || meta.seq < 0 || meta.seq >= meta.totalChunks) {
    throw new SessionError(`Invalid seq: ${meta.seq}`);
  }
  if (!Number.isInteger(meta.offsetSec) || meta.offsetSec < 0) {
    throw new SessionError(`Invalid offsetSec: ${meta.offsetSec}`);
  }
  if (meta.final && meta.seq !== meta.totalChunks - 1) {
    throw new SessionError("Only the last chunk may set final=true.");
  }
  if (file.size === 0) throw new SessionError("Empty chunk.");

  const receipt = await readReceipt(storageKey);
  if (receipt) {
    // New receipts describe the retained source. Verify the retry is compatible
    // before filling or checking its audio slot. Historical receipts have no
    // such contract, so return them without guessing and poisoning durable data.
    if (receipt.audio) {
      if (receipt.audio.chunkCount !== meta.totalChunks) {
        throw new SessionError(
          `Session totalChunks changed from ${receipt.audio.chunkCount} to ${meta.totalChunks}.`,
        );
      }
      try {
        await storeAudioChunk(storageKey, meta.seq, file);
      } catch (cause) {
        if (cause instanceof AudioChunkConflictError) throw new SessionError(cause.message);
        throw cause;
      }
    }
    return { status: "complete", sessionId: meta.sessionId, memory: receipt, needsDelivery: false };
  }

  // A lost HTTP response makes the device retry the same chunk. Reuse the
  // durable transcript instead of paying for transcription twice.
  const existingSession = await readSession(storageKey);
  if (existingSession && existingSession.totalChunks !== meta.totalChunks) {
    throw new SessionError(
      `Session totalChunks changed from ${existingSession.totalChunks} to ${meta.totalChunks}.`,
    );
  }
  const storedChunk = existingSession?.chunks.find((chunk) => chunk.seq === meta.seq) ?? null;
  if (storedChunk && storedChunk.offsetSec !== meta.offsetSec) {
    throw new SessionError(
      `Chunk ${meta.seq} offsetSec changed from ${storedChunk.offsetSec} to ${meta.offsetSec}.`,
    );
  }
  // The transcript is not the recording. Persist the exact WAV bytes only
  // after the request agrees with existing session metadata, but before any
  // external transcription call. A rejected request therefore has no durable
  // side effect, while provider failures never discard audio already accepted.
  try {
    await storeAudioChunk(storageKey, meta.seq, file);
  } catch (cause) {
    if (cause instanceof AudioChunkConflictError) throw new SessionError(cause.message);
    throw cause;
  }
  const transcript = storedChunk?.transcript ?? await transcribe(file);
  const session = storedChunk
    ? existingSession
    : await storeChunk(meta, transcript);
  if (!session) throw new Error("Hardware session disappeared after storing a chunk.");

  if (!meta.final) {
    return {
      status: "accepted",
      sessionId: session.sessionId,
      received: session.chunks.length,
      totalChunks: session.totalChunks,
    };
  }

  const received = new Set(session.chunks.map((chunk) => chunk.seq));
  const missing = Array.from({ length: session.totalChunks }, (_, seq) => seq)
    .filter((seq) => !received.has(seq));
  if (missing.length) {
    throw new IncompleteSessionError(received.size, session.totalChunks, missing);
  }

  // Exactly one request may finalize a session. Postgres provides the
  // cross-instance claim in production; the local set covers dev/test retries.
  // Losers wait for the winner's durable receipt instead of repeating analysis
  // or external integrations.
  if (!(await claimFinalization(storageKey))) {
    const completed = await waitForReceipt(storageKey);
    return {
      status: "complete",
      sessionId: session.sessionId,
      memory: completed,
      needsDelivery: false,
    };
  }

  try {
    const merged = mergeTranscripts(session.chunks);
    const sourceFileName = `${session.sessionId}.wav`;
    const analysis = await analyze(merged, sourceFileName);
    const now = new Date().toISOString();

    const tags = [
      "hardware",
      session.deviceId ? `device:${session.deviceId}` : "",
      session.chunks.length > 1 ? `chunks:${session.chunks.length}` : "",
    ].filter(Boolean);

    const memory: Memory = {
      id: hardwareMemoryId(session.sessionId, session.deviceId),
      createdAt: session.recordedAt || now,
      updatedAt: now,
      sourceFileName,
      durationSec: merged.durationSec,
      speakerCount: merged.speakerCount,
      tags,
      transcript: merged,
      analysis,
      integrations: [],
      audio: {
        kind: "hardware-session",
        sessionId: session.sessionId,
        deviceId: session.deviceId,
        chunkCount: session.totalChunks,
        contentType: "audio/wav",
      },
      isDemo: merged.provider === "demo" || analysis.provider === "demo",
    };

    await saveMemory(memory);
    await writeReceipt(storageKey, memory);
    await dropSession(storageKey);
    await releaseFinalization(storageKey);

    return { status: "complete", sessionId: session.sessionId, memory, needsDelivery: true };
  } catch (cause) {
    await releaseFinalization(storageKey).catch((releaseCause) => {
      console.error("[hardware] finalization claim cleanup failed:", releaseCause);
    });
    throw cause;
  }
}
