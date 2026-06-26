// Claude-backed analysis using structured outputs (messages.parse + zodOutputFormat).

import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";

import { claudeModel } from "@/lib/config";
import type { MemoryAnalysis, Transcript } from "@/lib/types";

import { ANALYSIS_SYSTEM, analysisSchema, finalizeAnalysis } from "./schema";

function buildUserContent(transcript: Transcript, fileName: string): string {
  return [
    `File: ${fileName}`,
    `Language: ${transcript.language}`,
    `Speakers: ${transcript.speakerCount}`,
    "",
    "Transcript:",
    transcript.fullText,
  ].join("\n");
}

export async function analyzeWithClaude(
  transcript: Transcript,
  fileName: string,
): Promise<MemoryAnalysis> {
  // ANTHROPIC_API_KEY is read from the environment automatically.
  const client = new Anthropic();

  const response = await client.messages.parse({
    model: claudeModel(),
    max_tokens: 8000,
    output_config: {
      format: zodOutputFormat(analysisSchema),
      effort: "high",
    },
    system: ANALYSIS_SYSTEM,
    messages: [
      {
        role: "user",
        content: buildUserContent(transcript, fileName),
      },
    ],
  });

  const parsed = response.parsed_output;
  if (!parsed) {
    throw new Error("Claude returned no parseable analysis output.");
  }

  return finalizeAnalysis(parsed, "claude");
}
