// Demo analysis (no LLM key). Derives a believable, transcript-connected result.

import type { MemoryAnalysis, Transcript } from "@/lib/types";

import { type RawAnalysis, finalizeAnalysis } from "./schema";

function titleFromFileName(fileName: string): string {
  const base = fileName.replace(/\.[^./\\]+$/, "");
  const cleaned = base.replace(/[._-]+/g, " ").trim();
  return cleaned.length > 0 ? cleaned : fileName;
}

/** First non-empty segment texts, for grounding summary/decisions/action items. */
function segmentTexts(transcript: Transcript, count: number): string[] {
  return transcript.segments
    .map((s) => s.text.trim())
    .filter((t) => t.length > 0)
    .slice(0, count);
}

export function analyzeDemo(
  transcript: Transcript,
  fileName: string,
): MemoryAnalysis {
  const title = titleFromFileName(fileName);
  const quotes = segmentTexts(transcript, 4);
  const q = (i: number): string | undefined => quotes[i];

  const raw: RawAnalysis = {
    title,
    summary:
      quotes.length > 0
        ? `Summary of ${title}. Key discussion covered "${quotes[0]}"${quotes[1] ? ` and "${quotes[1]}"` : ""}.`
        : `Summary of ${title}.`,
    highlights: [
      quotes[0] ? `Key point: ${quotes[0]}` : "Key points were captured.",
      `Speakers present: ${transcript.speakerCount}`,
      "Follow-ups and decisions were captured as an action plan.",
    ],
    topics: ["Recording summary", "Action items", "Decisions"],
    decisions: [
      { text: "Agreed to proceed to the next step.", sourceQuote: q(0) },
      { text: "Confirmed owners and timeline.", sourceQuote: q(1) },
    ],
    actionItems: [
      {
        title: "Write up and share the memory notes",
        owner: transcript.speakers[0]?.speakerLabel ?? "Owner",
        priority: "high",
        sourceQuote: q(0),
      },
      {
        title: "Schedule the follow-up",
        owner: transcript.speakers[1]?.speakerLabel ?? "Owner",
        priority: "medium",
        sourceQuote: q(1),
      },
      {
        title: "Execute on the agreed work",
        owner: transcript.speakers[0]?.speakerLabel ?? "Owner",
        priority: "medium",
        sourceQuote: q(2),
      },
    ],
    followups: [
      "Sharing the ARCA notes here. Please reply if anything is missing.",
      "Please reply with your availability for the next follow-up.",
    ],
    openQuestions: [
      "When should we finalize the next step?",
      "Are there additional resources we need?",
    ],
  };

  return finalizeAnalysis(
    raw,
    "demo",
    "Demo analysis result. Configure an LLM key for live analysis.",
  );
}
