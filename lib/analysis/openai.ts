// OpenAI-backed analysis using structured outputs, with a robust json_object fallback.

import OpenAI from "openai";
import { zodResponseFormat } from "openai/helpers/zod";

import { openAiNotesModel } from "@/lib/config";
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

export async function analyzeWithOpenAI(
  transcript: Transcript,
  fileName: string,
): Promise<MemoryAnalysis> {
  // OPENAI_API_KEY is read from the environment automatically.
  const client = new OpenAI();
  const model = openAiNotesModel();
  const userContent = buildUserContent(transcript, fileName);

  try {
    const completion = await client.chat.completions.parse({
      model,
      messages: [
        { role: "system", content: ANALYSIS_SYSTEM },
        { role: "user", content: userContent },
      ],
      response_format: zodResponseFormat(analysisSchema, "arca_analysis"),
    });

    const parsed = completion.choices[0]?.message.parsed;
    if (!parsed) {
      throw new Error("OpenAI returned no parseable analysis output.");
    }
    return finalizeAnalysis(parsed, "openai");
  } catch {
    // Fallback: ask for raw JSON and validate it with the same schema.
    const completion = await client.chat.completions.create({
      model,
      messages: [
        {
          role: "system",
          content: `${ANALYSIS_SYSTEM} Respond ONLY with a JSON object matching this shape: { title: string; summary: string; highlights: string[]; topics: string[]; decisions: { text: string; sourceQuote?: string }[]; actionItems: { title: string; owner?: string; due?: string; priority: "high"|"medium"|"low"; sourceQuote?: string }[]; followups: string[]; openQuestions: string[] }.`,
        },
        { role: "user", content: userContent },
      ],
      response_format: { type: "json_object" },
    });

    const content = completion.choices[0]?.message.content;
    if (!content) {
      throw new Error("OpenAI returned empty content for analysis.");
    }

    const parsed = analysisSchema.parse(JSON.parse(content) as unknown);
    return finalizeAnalysis(parsed, "openai");
  }
}
