// Shared analysis schema + assembly helpers.
// The zod schema describes ONLY what the model returns; provider/warning and the
// per-action-item id/status are added in code so the LLM never has to invent them.

import { z } from "zod";

import type { ActionItem, MemoryAnalysis, Provider } from "@/lib/types";

export const analysisSchema = z.object({
  title: z.string(),
  summary: z.string(),
  highlights: z.array(z.string()),
  topics: z.array(z.string()),
  decisions: z.array(
    z.object({
      text: z.string(),
      sourceQuote: z.string().optional(),
    }),
  ),
  actionItems: z.array(
    z.object({
      title: z.string(),
      owner: z.string().optional(),
      due: z.string().optional(),
      priority: z.enum(["high", "medium", "low"]),
      sourceQuote: z.string().optional(),
    }),
  ),
  followups: z.array(z.string()),
  openQuestions: z.array(z.string()),
});

export type RawAnalysis = z.infer<typeof analysisSchema>;

export const ANALYSIS_SYSTEM = [
  "You convert meeting transcripts into concise, product-grade ARCA memory notes.",
  "From the transcript, extract: a short title and one-paragraph summary; bullet highlights and topics;",
  "the decisions that were made; a concrete action plan (with clear owners, due dates, and priority whenever they are stated);",
  "draft follow-up messages the user could send; and the open questions / unresolved threads.",
  "Ground every decision and action item in the transcript by including a short verbatim sourceQuote whenever one exists.",
  "Do NOT invent facts, owners, dates, or decisions that are not supported by the transcript.",
  "Respond entirely in English, even when the transcript is Korean or mixed-language.",
].join(" ");

/** Adds the code-owned fields (provider, warning, action item id/status) and
 *  assembles the final MemoryAnalysis the rest of the app consumes. */
export function finalizeAnalysis(
  raw: RawAnalysis,
  provider: Extract<Provider, "claude" | "openai" | "demo">,
  warning?: string,
): MemoryAnalysis {
  const actionItems: ActionItem[] = raw.actionItems.map((item) => ({
    id: crypto.randomUUID(),
    title: item.title,
    owner: item.owner,
    due: item.due,
    priority: item.priority,
    status: "todo",
    sourceQuote: item.sourceQuote,
  }));

  return {
    provider,
    title: raw.title,
    summary: raw.summary,
    highlights: raw.highlights,
    topics: raw.topics,
    decisions: raw.decisions.map((d) => ({
      text: d.text,
      sourceQuote: d.sourceQuote,
    })),
    actionItems,
    followups: raw.followups,
    openQuestions: raw.openQuestions,
    warning,
  };
}
