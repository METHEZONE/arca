// Analysis entry point: routes to the configured provider, falls back to demo on error.

import { analysisProvider } from "@/lib/config";
import type { MemoryAnalysis, Transcript } from "@/lib/types";

import { analyzeWithClaude } from "./claude";
import { analyzeDemo } from "./demo";
import { analyzeWithOpenAI } from "./openai";

function truncate(message: string, max = 200): string {
  return message.length > max ? `${message.slice(0, max)}…` : message;
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

export async function analyze(
  transcript: Transcript,
  fileName: string,
): Promise<MemoryAnalysis> {
  const provider = analysisProvider();

  if (provider === "demo") {
    return analyzeDemo(transcript, fileName);
  }

  try {
    return provider === "claude"
      ? await analyzeWithClaude(transcript, fileName)
      : await analyzeWithOpenAI(transcript, fileName);
  } catch (error) {
    const analysis = analyzeDemo(transcript, fileName);
    analysis.warning = `${provider} analysis failed, so ARCA used demo analysis: ${truncate(errorMessage(error))}`;
    return analysis;
  }
}
