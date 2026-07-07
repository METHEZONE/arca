// ARCA shared domain model.
// Every layer (transcription, analysis, second brain, integrations, API, UI)
// speaks in these types. Keep this file dependency-free.

export type Provider = "elevenlabs" | "claude" | "openai" | "demo";

/* ---------------------------------------------------------------- *
 * Transcription + speaker diarization
 * ---------------------------------------------------------------- */

export type TranscriptSegment = {
  /** Stable speaker id from diarization, e.g. "speaker_0". */
  speaker: string;
  /** Human label resolved for display, e.g. "Speaker 1" or a real name. */
  speakerLabel: string;
  text: string;
  startMs: number;
  endMs: number;
};

export type Transcript = {
  provider: Extract<Provider, "elevenlabs" | "openai" | "demo">;
  language: string;
  durationSec: number;
  /** Speaker-prefixed plain text, good for reading and for LLM context. */
  fullText: string;
  segments: TranscriptSegment[];
  speakerCount: number;
  /** Per-speaker rollup for the UI (talk time, segment count). */
  speakers: SpeakerSummary[];
  warning?: string;
};

export type SpeakerSummary = {
  speaker: string;
  speakerLabel: string;
  segmentCount: number;
  talkTimeSec: number;
};

/* ---------------------------------------------------------------- *
 * Analysis — notes, decisions, and the action plan
 * ---------------------------------------------------------------- */

export type Priority = "high" | "medium" | "low";
export type ActionStatus = "todo" | "doing" | "done";

export type ActionItem = {
  id: string;
  title: string;
  owner?: string;
  due?: string;
  priority: Priority;
  status: ActionStatus;
  /** Verbatim transcript evidence so claims are grounded, not invented. */
  sourceQuote?: string;
};

export type Decision = {
  text: string;
  sourceQuote?: string;
};

export type MemoryAnalysis = {
  provider: Extract<Provider, "claude" | "openai" | "demo">;
  title: string;
  /** One-paragraph executive summary. */
  summary: string;
  /** Short bullet highlights. */
  highlights: string[];
  topics: string[];
  decisions: Decision[];
  actionItems: ActionItem[];
  /** Draft follow-up messages the user could send. */
  followups: string[];
  /** Open questions / unresolved threads. */
  openQuestions: string[];
  warning?: string;
};

/* ---------------------------------------------------------------- *
 * Integrations
 * ---------------------------------------------------------------- */

export type IntegrationTarget = "obsidian" | "notion" | "slack";

export type IntegrationResult = {
  target: IntegrationTarget;
  status: "success" | "skipped" | "error";
  /** URL, file path, or error message. */
  detail?: string;
  at: string;
};

/* ---------------------------------------------------------------- *
 * The second-brain entry
 * ---------------------------------------------------------------- */

export type Memory = {
  id: string;
  createdAt: string;
  updatedAt: string;
  sourceFileName: string;
  durationSec: number;
  speakerCount: number;
  tags: string[];
  transcript: Transcript;
  analysis: MemoryAnalysis;
  integrations: IntegrationResult[];
  /** True when any layer ran in demo (no-key) mode. */
  isDemo: boolean;
};

/** Lightweight projection for the memory feed (no full transcript). */
export type MemorySummary = {
  id: string;
  createdAt: string;
  title: string;
  summary: string;
  sourceFileName: string;
  durationSec: number;
  speakerCount: number;
  topics: string[];
  actionItemCount: number;
  openActionItemCount: number;
  tags: string[];
  integrations: IntegrationResult[];
  isDemo: boolean;
};

export function toMemorySummary(memory: Memory): MemorySummary {
  return {
    id: memory.id,
    createdAt: memory.createdAt,
    title: memory.analysis.title,
    summary: memory.analysis.summary,
    sourceFileName: memory.sourceFileName,
    durationSec: memory.durationSec,
    speakerCount: memory.speakerCount,
    topics: memory.analysis.topics,
    actionItemCount: memory.analysis.actionItems.length,
    openActionItemCount: memory.analysis.actionItems.filter((a) => a.status !== "done").length,
    tags: memory.tags,
    integrations: memory.integrations,
    isDemo: memory.isDemo,
  };
}

/* ---------------------------------------------------------------- *
 * Capability reporting (drives the "what's wired" UI)
 * ---------------------------------------------------------------- */

export type CapabilityKey =
  | "hardware"
  | "transcription"
  | "analysis"
  | "obsidian"
  | "notion"
  | "slack";

export type Capability = {
  key: CapabilityKey;
  label: string;
  configured: boolean;
  provider?: string;
  detail: string;
};

export type Capabilities = {
  demoMode: boolean;
  analysisProvider: "claude" | "openai" | "demo";
  autoPushTargets: IntegrationTarget[];
  items: Capability[];
};
