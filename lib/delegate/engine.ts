// The "arca it" delegation engine.
//
// A delegation is the product's core promise made executable: take a two-word
// handoff ("arca it — wrap up this meeting"), recall the relevant memories,
// reason over them (Claude when a key is present, grounded demo otherwise),
// draft the artifacts, file the report back into the second brain, and report
// completion. runDelegation streams each step so the UI can show the loop
// happening in real time.

import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import { z } from "zod";

import { analysisProvider, anthropicKey, claudeModel } from "@/lib/config";
import { getMemory, listMemories, newMemoryId, saveMemory } from "@/lib/secondbrain/store";
import type { Memory, MemorySummary } from "@/lib/types";

/* ---------------------------------------------------------------- *
 * Types
 * ---------------------------------------------------------------- */

export type DelegationStepKey = "recall" | "reason" | "draft" | "file" | "report";

export type DelegationOpenAction = {
  title: string;
  owner?: string;
  memoryTitle: string;
};

export type DelegationReport = {
  id: string;
  command: string;
  provider: "claude" | "demo";
  /** Short, punchy completion line, e.g. "wrapped up — 2 follow-ups drafted". */
  headline: string;
  summary: string;
  recapMarkdown: string;
  followups: string[];
  openActions: DelegationOpenAction[];
  memoriesUsed: Array<{ id: string; title: string }>;
  /** The second-brain memory this report was filed as. */
  filedMemoryId?: string;
  elapsedMs: number;
  createdAt: string;
};

export type DelegationEvent =
  | {
      type: "step";
      key: DelegationStepKey;
      status: "start" | "done";
      label: string;
      detail?: string;
    }
  | { type: "report"; report: DelegationReport; memory: Memory | null }
  | { type: "error"; message: string };

/* ---------------------------------------------------------------- *
 * Recall — score memories against the command
 * ---------------------------------------------------------------- */

const STOPWORDS = new Set([
  "the", "a", "an", "my", "me", "i", "it", "this", "that", "for", "with",
  "and", "or", "to", "of", "in", "on", "at", "up", "all", "everyone",
  "arca", "please", "whats", "what", "is", "are", "do", "did", "we",
]);

function terms(command: string): string[] {
  return command
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .split(/\s+/)
    .filter((t) => t.length > 2 && !STOPWORDS.has(t));
}

function scoreMemory(summary: MemorySummary, queryTerms: string[]): number {
  const title = summary.title.toLowerCase();
  const topics = [...summary.topics, ...summary.tags].join(" ").toLowerCase();
  const text = summary.summary.toLowerCase();
  let score = 0;
  for (const t of queryTerms) {
    if (title.includes(t)) score += 3;
    if (topics.includes(t)) score += 2;
    if (text.includes(t)) score += 1;
  }
  // Prefer memories with substance — an empty or unintelligible recording
  // shouldn't outrank a real meeting just by being newer.
  if (summary.actionItemCount > 0) score += 1;
  return score;
}

/** Pick the memories a delegation should reason over: keyword-matched first,
 *  then most recent. Prior delegation reports are excluded so "my latest
 *  meeting" never recalls a report about itself. */
export async function recallMemories(command: string, limit = 3): Promise<Memory[]> {
  const all = (await listMemories()).filter((m) => !m.tags.includes("delegation"));
  const queryTerms = terms(command);

  const ranked = [...all].sort((a, b) => {
    const diff = scoreMemory(b, queryTerms) - scoreMemory(a, queryTerms);
    if (diff !== 0) return diff;
    return a.createdAt < b.createdAt ? 1 : -1;
  });

  const picked: Memory[] = [];
  for (const summary of ranked.slice(0, limit)) {
    const memory = await getMemory(summary.id);
    if (memory) picked.push(memory);
  }
  return picked;
}

/* ---------------------------------------------------------------- *
 * Demo reasoning — grounded in the recalled memories, no LLM needed
 * ---------------------------------------------------------------- */

type Drafted = {
  headline: string;
  summary: string;
  recapMarkdown: string;
  followups: string[];
  openActions: DelegationOpenAction[];
};

function draftDemo(command: string, memories: Memory[]): Drafted {
  const openActions: DelegationOpenAction[] = memories.flatMap((m) =>
    m.analysis.actionItems
      .filter((a) => a.status !== "done")
      .map((a) => ({ title: a.title, owner: a.owner, memoryTitle: m.analysis.title })),
  );
  const followups = memories.flatMap((m) => m.analysis.followups).slice(0, 4);

  const sections = memories.map((m) => {
    const decisions = m.analysis.decisions.map((d) => `- ${d.text}`).join("\n");
    const actions = m.analysis.actionItems
      .map((a) => `- [${a.status === "done" ? "x" : " "}] ${a.title}${a.owner ? ` — ${a.owner}` : ""}`)
      .join("\n");
    return [
      `## ${m.analysis.title}`,
      m.analysis.summary,
      decisions ? `\n**Decisions**\n${decisions}` : "",
      actions ? `\n**Actions**\n${actions}` : "",
    ]
      .filter(Boolean)
      .join("\n");
  });

  const recapMarkdown = [`# arca it — ${command}`, ...sections].join("\n\n");

  const bits = [
    `${memories.length} ${memories.length === 1 ? "memory" : "memories"} recalled`,
    followups.length > 0 ? `${followups.length} follow-ups drafted` : null,
    openActions.length > 0 ? `${openActions.length} open actions surfaced` : null,
  ].filter(Boolean);

  return {
    headline: `done — ${bits.join(", ")}`,
    summary:
      memories.length > 0
        ? `Handled "${command}" across ${memories
            .map((m) => `“${m.analysis.title}”`)
            .join(", ")}. The recap below is grounded in those memories; follow-up drafts and open actions are pulled from their action plans.`
        : `No memories matched "${command}" yet — record or upload something first, then delegate again.`,
    recapMarkdown,
    followups,
    openActions,
  };
}

/* ---------------------------------------------------------------- *
 * Claude reasoning
 * ---------------------------------------------------------------- */

const delegateSchema = z.object({
  headline: z.string(),
  summary: z.string(),
  recapMarkdown: z.string(),
  followups: z.array(z.string()),
});

const DELEGATE_SYSTEM = [
  "You are ARCA, a second-self companion that completes delegated work end to end.",
  "The user delegated a task with the given command. You are given their relevant second-brain memories",
  "(meeting summaries, decisions, action plans, follow-up drafts).",
  "Produce: a short lowercase completion headline (e.g. \"wrapped up — 3 follow-ups drafted\");",
  "a one-paragraph summary of what you did; a recap document in markdown that fully resolves the command;",
  "and ready-to-send follow-up drafts when the command calls for them.",
  "Ground everything ONLY in the provided memories. Never invent people, decisions, or facts.",
  "Match the user's language (English in, English out; Korean in, Korean out).",
].join(" ");

function memoryContext(memories: Memory[]): string {
  return memories
    .map((m) => {
      const actions = m.analysis.actionItems
        .map((a) => `- (${a.status}) ${a.title}${a.owner ? ` — owner: ${a.owner}` : ""}`)
        .join("\n");
      return [
        `### Memory: ${m.analysis.title} (${m.createdAt.slice(0, 10)})`,
        `Summary: ${m.analysis.summary}`,
        `Decisions: ${m.analysis.decisions.map((d) => d.text).join(" | ") || "none"}`,
        `Action plan:\n${actions || "none"}`,
        `Existing follow-up drafts: ${m.analysis.followups.join(" | ") || "none"}`,
        `Transcript excerpt:\n${m.transcript.fullText.slice(0, 1600)}`,
      ].join("\n");
    })
    .join("\n\n");
}

async function draftWithClaude(command: string, memories: Memory[]): Promise<Drafted> {
  const client = new Anthropic();
  const response = await client.messages.parse({
    model: claudeModel(),
    max_tokens: 4000,
    output_config: { format: zodOutputFormat(delegateSchema) },
    system: DELEGATE_SYSTEM,
    messages: [
      {
        role: "user",
        content: `Command: arca it — ${command}\n\n${memoryContext(memories)}`,
      },
    ],
  });

  const parsed = response.parsed_output;
  if (!parsed) throw new Error("Claude returned no parseable delegation output.");

  const openActions: DelegationOpenAction[] = memories.flatMap((m) =>
    m.analysis.actionItems
      .filter((a) => a.status !== "done")
      .map((a) => ({ title: a.title, owner: a.owner, memoryTitle: m.analysis.title })),
  );

  return { ...parsed, openActions };
}

/* ---------------------------------------------------------------- *
 * Filing — the report itself becomes a second-brain memory
 * ---------------------------------------------------------------- */

function reportToMemory(report: DelegationReport): Memory {
  const now = report.createdAt;
  const transcript = {
    provider: "demo" as const,
    language: "en",
    durationSec: Math.max(1, Math.round(report.elapsedMs / 1000)),
    fullText: `You: arca it — ${report.command}\nARCA: ${report.summary}`,
    segments: [
      {
        speaker: "speaker_0",
        speakerLabel: "You",
        text: `arca it — ${report.command}`,
        startMs: 0,
        endMs: 1600,
      },
      {
        speaker: "speaker_1",
        speakerLabel: "ARCA",
        text: report.summary,
        startMs: 2300,
        endMs: 2300 + Math.max(1800, report.summary.length * 60),
      },
    ],
    speakerCount: 2,
    speakers: [
      { speaker: "speaker_0", speakerLabel: "You", segmentCount: 1, talkTimeSec: 2 },
      { speaker: "speaker_1", speakerLabel: "ARCA", segmentCount: 1, talkTimeSec: 4 },
    ],
  };

  return {
    id: report.filedMemoryId ?? newMemoryId(),
    createdAt: now,
    updatedAt: now,
    sourceFileName: `delegation-${report.id}.md`,
    durationSec: transcript.durationSec,
    speakerCount: 2,
    tags: ["delegation"],
    transcript,
    analysis: {
      provider: report.provider === "claude" ? "claude" : "demo",
      title: `arca it — ${report.command}`,
      summary: report.summary,
      highlights: [report.headline],
      topics: ["Delegation report"],
      decisions: [],
      actionItems: [],
      followups: report.followups,
      openQuestions: [],
    },
    integrations: [],
    isDemo: report.provider !== "claude",
  };
}

/* ---------------------------------------------------------------- *
 * The run — an async generator of streamed events
 * ---------------------------------------------------------------- */

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function* runDelegation(command: string): AsyncGenerator<DelegationEvent> {
  const startedAt = Date.now();
  const provider: "claude" | "demo" =
    anthropicKey() && analysisProvider() === "claude" ? "claude" : "demo";
  // Demo reasoning is instant; a short beat per step keeps the streamed loop
  // legible instead of collapsing into a single flash.
  const beat = provider === "demo" ? 650 : 120;

  try {
    yield { type: "step", key: "recall", status: "start", label: "Recalling memories" };
    const memories = await recallMemories(command);
    await sleep(beat);
    yield {
      type: "step",
      key: "recall",
      status: "done",
      label: "Recalling memories",
      detail:
        memories.length > 0
          ? memories.map((m) => m.analysis.title).join(" · ")
          : "no matching memories — starting fresh",
    };

    yield {
      type: "step",
      key: "reason",
      status: "start",
      label: provider === "claude" ? "Reasoning with Claude" : "Reasoning (demo mode)",
    };
    let drafted: Drafted;
    let reasonedWith: "claude" | "demo" = provider;
    if (provider === "claude" && memories.length > 0) {
      try {
        drafted = await draftWithClaude(command, memories);
      } catch {
        // A failing LLM never kills a delegation — degrade to grounded demo
        // reasoning, exactly like the ingest pipeline does.
        drafted = draftDemo(command, memories);
        reasonedWith = "demo";
      }
    } else {
      drafted = draftDemo(command, memories);
      reasonedWith = "demo";
    }
    await sleep(beat);
    yield {
      type: "step",
      key: "reason",
      status: "done",
      label: reasonedWith === "claude" ? "Reasoning with Claude" : "Reasoning (demo mode)",
      detail:
        provider === "claude" && reasonedWith === "demo"
          ? `claude unavailable — grounded demo reasoning · ${drafted.headline}`
          : drafted.headline,
    };

    yield { type: "step", key: "draft", status: "start", label: "Drafting artifacts" };
    await sleep(beat);
    yield {
      type: "step",
      key: "draft",
      status: "done",
      label: "Drafting artifacts",
      detail: `recap + ${drafted.followups.length} follow-up ${
        drafted.followups.length === 1 ? "draft" : "drafts"
      }`,
    };

    const report: DelegationReport = {
      id: newMemoryId(),
      command,
      provider: reasonedWith,
      ...drafted,
      memoriesUsed: memories.map((m) => ({ id: m.id, title: m.analysis.title })),
      elapsedMs: 0,
      createdAt: new Date().toISOString(),
    };

    yield { type: "step", key: "file", status: "start", label: "Filing to second brain" };
    let filed: Memory | null = null;
    try {
      report.filedMemoryId = newMemoryId();
      filed = reportToMemory(report);
      await saveMemory(filed);
    } catch {
      report.filedMemoryId = undefined;
      filed = null;
    }
    await sleep(beat);
    yield {
      type: "step",
      key: "file",
      status: "done",
      label: "Filing to second brain",
      detail: filed ? "report saved as a memory" : "could not persist — report is ephemeral",
    };

    report.elapsedMs = Date.now() - startedAt;
    yield {
      type: "step",
      key: "report",
      status: "done",
      label: "Reporting back",
      detail: `done in ${(report.elapsedMs / 1000).toFixed(1)}s`,
    };
    yield { type: "report", report, memory: filed };
  } catch (err: unknown) {
    yield {
      type: "error",
      message: err instanceof Error ? err.message : "Delegation failed.",
    };
  }
}
