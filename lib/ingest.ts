import { autoPushTargets } from "@/lib/config";
import { transcribe } from "@/lib/transcription/elevenlabs";
import { analyze } from "@/lib/analysis";
import { pushToTargets } from "@/lib/integrations";
import { newMemoryId, saveMemory, updateMemory } from "@/lib/secondbrain/store";
import type { Memory, Transcript } from "@/lib/types";

export const MAX_RECORDING_BYTES = 100 * 1024 * 1024;

const SUPPORTED_PREFIXES = ["audio/", "video/"];
const EXTRA_TYPES = new Set(["application/octet-stream", ""]);

export type IngestMetadata = {
  source?: "dashboard" | "hardware";
  deviceId?: string;
  recordedAt?: string;
  battery?: string;
};

export function validateRecording(file: File): string | null {
  if (file.size === 0) return "Empty files cannot be processed.";
  if (file.size > MAX_RECORDING_BYTES) return "The current upload limit is 100MB.";
  if (
    file.type &&
    !SUPPORTED_PREFIXES.some((p) => file.type.startsWith(p)) &&
    !EXTRA_TYPES.has(file.type)
  ) {
    return `Unsupported file type: ${file.type}`;
  }
  return null;
}

export async function ingestRecording(
  file: File,
  metadata: IngestMetadata = {},
): Promise<Memory> {
  const validationError = validateRecording(file);
  if (validationError) throw new IngestError(validationError);

  const fileName = file.name || "recording";

  let transcript: Transcript;
  try {
    transcript = await transcribe(file);
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause);
    transcript = fallbackTranscript(fileName, message);
  }

  const analysis = await analyze(transcript, fileName);
  const now = new Date().toISOString();
  const tags = [
    metadata.source === "hardware" ? "hardware" : "dashboard",
    metadata.deviceId ? `device:${metadata.deviceId}` : "",
  ].filter(Boolean);

  const memory: Memory = {
    id: newMemoryId(),
    createdAt: metadata.recordedAt || now,
    updatedAt: now,
    sourceFileName: fileName,
    durationSec: transcript.durationSec,
    speakerCount: transcript.speakerCount,
    tags,
    transcript,
    analysis,
    integrations: [],
    isDemo: transcript.provider === "demo" || analysis.provider === "demo",
  };
  await saveMemory(memory);

  const targets = autoPushTargets();
  if (targets.length === 0) return memory;

  try {
    const results = await pushToTargets(memory, targets);
    const updated = await updateMemory(memory.id, { integrations: results });
    if (updated) return updated;
    memory.integrations = results;
  } catch {
    // Auto-push is best-effort; the memory is already saved.
  }

  return memory;
}

export async function ingestText(
  text: string,
  metadata: IngestMetadata = {},
): Promise<Memory> {
  const trimmed = text.trim();
  if (!trimmed) throw new IngestError("Text input is required.");

  const transcript: Transcript = {
    provider: "demo",
    language: "en",
    durationSec: 0,
    fullText: `Speaker 1: ${trimmed}`,
    segments: [
      {
        speaker: "speaker_0",
        speakerLabel: "Speaker 1",
        text: trimmed,
        startMs: 0,
        endMs: 0,
      },
    ],
    speakerCount: 1,
    speakers: [
      { speaker: "speaker_0", speakerLabel: "Speaker 1", segmentCount: 1, talkTimeSec: 0 },
    ],
  };

  const sourceFileName = "typed-notes.txt";
  const analysis = await analyze(transcript, sourceFileName);
  const now = new Date().toISOString();
  const tags = [metadata.source === "hardware" ? "hardware" : "dashboard", "text"].filter(Boolean);

  const memory: Memory = {
    id: newMemoryId(),
    createdAt: metadata.recordedAt || now,
    updatedAt: now,
    sourceFileName,
    durationSec: transcript.durationSec,
    speakerCount: transcript.speakerCount,
    tags,
    transcript,
    analysis,
    integrations: [],
    isDemo: analysis.provider === "demo",
  };
  await saveMemory(memory);

  const targets = autoPushTargets();
  if (targets.length === 0) return memory;

  try {
    const results = await pushToTargets(memory, targets);
    const updated = await updateMemory(memory.id, { integrations: results });
    if (updated) return updated;
    memory.integrations = results;
  } catch {
    // Auto-push is best-effort; the memory is already saved.
  }

  return memory;
}

export class IngestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "IngestError";
  }
}

function fallbackTranscript(fileName: string, errorMessage: string): Transcript {
  const text = `The transcription provider failed, so ARCA saved a temporary transcript for ${fileName}.`;
  return {
    provider: "demo",
    language: "en",
    durationSec: 0,
    fullText: `Speaker 1: ${text}`,
    segments: [
      {
        speaker: "speaker_0",
        speakerLabel: "Speaker 1",
        text,
        startMs: 0,
        endMs: 0,
      },
    ],
    speakerCount: 1,
    speakers: [
      { speaker: "speaker_0", speakerLabel: "Speaker 1", segmentCount: 1, talkTimeSec: 0 },
    ],
    warning: `Live transcription failed: ${errorMessage.slice(0, 200)}`,
  };
}
