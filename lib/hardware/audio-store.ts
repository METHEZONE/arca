import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

import { neon, type NeonQueryFunction } from "@neondatabase/serverless";

import { dataDir } from "@/lib/config";
import { durableStoreConfigured } from "@/lib/persistence/kv";

export type StoredAudioChunk = {
  seq: number;
  bytes: Uint8Array;
  contentType: string;
  fileName: string;
  sha256: string;
  size: number;
};

export type AudioChunkSummary = Omit<StoredAudioChunk, "bytes">;

export class AudioChunkConflictError extends Error {}

let client: NeonQueryFunction<false, false> | undefined;
let schemaReady: Promise<void> | undefined;

function database(): NeonQueryFunction<false, false> {
  const connectionString = process.env.DATABASE_URL?.trim();
  if (!connectionString) throw new Error("DATABASE_URL is not configured.");
  client ??= neon(connectionString);
  return client;
}

async function ensureSchema(): Promise<void> {
  schemaReady ??= (async () => {
    const sql = database();
    await sql`
      CREATE TABLE IF NOT EXISTS arca_audio_chunks (
        storage_key TEXT NOT NULL,
        seq INTEGER NOT NULL,
        bytes BYTEA NOT NULL,
        content_type TEXT NOT NULL,
        file_name TEXT NOT NULL,
        sha256 TEXT NOT NULL,
        size INTEGER NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (storage_key, seq)
      )
    `;
  })();
  await schemaReady;
}

function baseDir(): string {
  const configured = dataDir();
  if (process.env.VERCEL && !isAbsolute(configured)) return join("/tmp", configured);
  if (isAbsolute(configured)) return configured;
  return join(/* turbopackIgnore: true */ process.cwd(), configured);
}

function audioDir(storageKey: string): string {
  return join(baseDir(), "hardware-audio", storageKey);
}

function audioPath(storageKey: string, seq: number): string {
  return join(audioDir(storageKey), `${seq}.bin`);
}

function metaPath(storageKey: string, seq: number): string {
  return join(audioDir(storageKey), `${seq}.json`);
}

function digest(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function decodeBytea(value: unknown): Uint8Array {
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (typeof value === "string" && value.startsWith("\\x")) {
    return Uint8Array.from(Buffer.from(value.slice(2), "hex"));
  }
  throw new Error("Postgres returned an unsupported BYTEA representation.");
}

export function hardwareStorageKey(sessionId: string, deviceId?: string): string {
  return createHash("sha256")
    .update(`${deviceId || "unknown"}\0${sessionId}`)
    .digest("hex");
}

export async function storeAudioChunk(
  storageKey: string,
  seq: number,
  file: File,
): Promise<AudioChunkSummary> {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const summary: AudioChunkSummary = {
    seq,
    contentType: file.type || "audio/wav",
    fileName: file.name || `${seq}.wav`,
    sha256: digest(bytes),
    size: bytes.byteLength,
  };

  if (durableStoreConfigured()) {
    await ensureSchema();
    const sql = database();
    await sql`
      INSERT INTO arca_audio_chunks
        (storage_key, seq, bytes, content_type, file_name, sha256, size)
      VALUES
        (${storageKey}, ${seq}, ${bytes}, ${summary.contentType},
         ${summary.fileName}, ${summary.sha256}, ${summary.size})
      ON CONFLICT (storage_key, seq) DO NOTHING
    `;
    const rows = await sql`
      SELECT seq, content_type, file_name, sha256, size
      FROM arca_audio_chunks
      WHERE storage_key = ${storageKey} AND seq = ${seq}
      LIMIT 1
    `;
    if (!rows.length || rows[0].sha256 !== summary.sha256) {
      throw new AudioChunkConflictError(`Audio chunk ${seq} was retried with different bytes.`);
    }
    return {
      seq: Number(rows[0].seq),
      contentType: String(rows[0].content_type),
      fileName: String(rows[0].file_name),
      sha256: String(rows[0].sha256),
      size: Number(rows[0].size),
    };
  }

  await mkdir(audioDir(storageKey), { recursive: true });
  try {
    await writeFile(audioPath(storageKey, seq), bytes, { flag: "wx" });
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code !== "EEXIST") throw cause;
    const existingBytes = await readFile(audioPath(storageKey, seq));
    if (digest(existingBytes) !== summary.sha256) {
      throw new AudioChunkConflictError(`Audio chunk ${seq} was retried with different bytes.`);
    }
  }
  try {
    await writeFile(metaPath(storageKey, seq), JSON.stringify(summary), { flag: "wx" });
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code !== "EEXIST") throw cause;
  }
  const stored = await readAudioChunk(storageKey, seq);
  if (!stored || stored.sha256 !== summary.sha256) {
    throw new AudioChunkConflictError(`Audio chunk ${seq} was retried with different bytes.`);
  }
  return {
    seq: stored.seq,
    contentType: stored.contentType,
    fileName: stored.fileName,
    sha256: stored.sha256,
    size: stored.size,
  };
}

export async function readAudioChunk(
  storageKey: string,
  seq: number,
): Promise<StoredAudioChunk | null> {
  if (durableStoreConfigured()) {
    await ensureSchema();
    const sql = database();
    const rows = await sql`
      SELECT seq, bytes, content_type, file_name, sha256, size
      FROM arca_audio_chunks
      WHERE storage_key = ${storageKey} AND seq = ${seq}
      LIMIT 1
    `;
    if (!rows.length) return null;
    return {
      seq: Number(rows[0].seq),
      bytes: decodeBytea(rows[0].bytes),
      contentType: String(rows[0].content_type),
      fileName: String(rows[0].file_name),
      sha256: String(rows[0].sha256),
      size: Number(rows[0].size),
    };
  }

  try {
    const [bytes, rawMeta] = await Promise.all([
      readFile(audioPath(storageKey, seq)),
      readFile(metaPath(storageKey, seq), "utf-8"),
    ]);
    const meta = JSON.parse(rawMeta) as AudioChunkSummary;
    return { ...meta, bytes };
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw cause;
  }
}

export async function listAudioChunks(storageKey: string): Promise<AudioChunkSummary[]> {
  if (durableStoreConfigured()) {
    await ensureSchema();
    const sql = database();
    const rows = await sql`
      SELECT seq, content_type, file_name, sha256, size
      FROM arca_audio_chunks
      WHERE storage_key = ${storageKey}
      ORDER BY seq ASC
    `;
    return rows.map((row) => ({
      seq: Number(row.seq),
      contentType: String(row.content_type),
      fileName: String(row.file_name),
      sha256: String(row.sha256),
      size: Number(row.size),
    }));
  }

  try {
    const names = await readdir(audioDir(storageKey));
    const chunks = await Promise.all(
      names.filter((name) => /^\d+\.json$/.test(name)).map(async (name) =>
        JSON.parse(await readFile(join(audioDir(storageKey), name), "utf-8")) as AudioChunkSummary),
    );
    return chunks.sort((a, b) => a.seq - b.seq);
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw cause;
  }
}
