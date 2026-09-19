import {
  assemblyAiKey,
  elevenLabsKey,
  openAiKey,
  transcriptionProvider,
  type TranscriptionProvider,
} from "@/lib/config";
import type { Transcript } from "@/lib/types";
import { transcribeWithAssemblyAI } from "@/lib/transcription/assemblyai";
import { buildDemoTranscript, transcribeWithElevenLabs } from "@/lib/transcription/elevenlabs";
import { transcribeWithOpenAI } from "@/lib/transcription/openai";

type Candidate = Exclude<TranscriptionProvider, "auto" | "demo">;

function candidates(): Candidate[] {
  const provider = transcriptionProvider();
  if (provider === "assemblyai") return ["assemblyai"];
  if (provider === "openai") return ["openai"];
  if (provider === "elevenlabs") return ["elevenlabs"];
  if (provider === "demo") return [];

  // Auto order: AssemblyAI first (ARCA's primary voice AI partner), then
  // OpenAI, then ElevenLabs as fallbacks.
  const ordered: Candidate[] = [];
  if (assemblyAiKey()) ordered.push("assemblyai");
  if (openAiKey()) ordered.push("openai");
  if (elevenLabsKey()) ordered.push("elevenlabs");
  return ordered;
}

export async function transcribe(file: File): Promise<Transcript> {
  const ordered = candidates();
  if (ordered.length === 0) return buildDemoTranscript();

  const failures: string[] = [];
  for (const provider of ordered) {
    try {
      if (provider === "assemblyai") return await transcribeWithAssemblyAI(file);
      if (provider === "openai") return await transcribeWithOpenAI(file);
      return await transcribeWithElevenLabs(file);
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : String(cause);
      failures.push(`${provider}: ${message}`);
      if (transcriptionProvider() !== "auto") break;
    }
  }

  throw new Error(`All transcription providers failed. ${failures.join(" | ")}`);
}
