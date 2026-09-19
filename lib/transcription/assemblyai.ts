import { assemblyAiKey, assemblyAiSpeechModel } from "@/lib/config";
import type { SpeakerSummary, Transcript, TranscriptSegment } from "@/lib/types";

const BASE_URL = "https://api.assemblyai.com/v2";

type AssemblyAiUtterance = {
  speaker?: string;
  text?: string;
  start?: number; // ms
  end?: number; // ms
};

type AssemblyAiTranscriptResponse = {
  id: string;
  status: "queued" | "processing" | "completed" | "error";
  error?: string;
  text?: string;
  language_code?: string;
  audio_duration?: number; // seconds
  utterances?: AssemblyAiUtterance[] | null;
};

function resolveSpeakerLabel(speakerId: string, order: Map<string, number>): string {
  const n = order.get(speakerId);
  return `Speaker ${(n ?? 0) + 1}`;
}

async function uploadAudio(file: File, apiKey: string): Promise<string> {
  const res = await fetch(`${BASE_URL}/upload`, {
    method: "POST",
    headers: { Authorization: apiKey },
    body: file,
  });
  if (!res.ok) {
    const bodyText = await res.text();
    throw new Error(`assemblyai upload ${res.status}: ${bodyText.slice(0, 240)}`);
  }
  const { upload_url } = (await res.json()) as { upload_url: string };
  return upload_url;
}

async function requestTranscript(
  audioUrl: string,
  apiKey: string,
): Promise<string> {
  const res = await fetch(`${BASE_URL}/transcript`, {
    method: "POST",
    headers: {
      Authorization: apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      audio_url: audioUrl,
      speaker_labels: true,
      speech_model: assemblyAiSpeechModel(),
    }),
  });
  if (!res.ok) {
    const bodyText = await res.text();
    throw new Error(`assemblyai transcript ${res.status}: ${bodyText.slice(0, 240)}`);
  }
  const data = (await res.json()) as AssemblyAiTranscriptResponse;
  return data.id;
}

async function pollTranscript(
  id: string,
  apiKey: string,
  { intervalMs = 3000, timeoutMs = 5 * 60 * 1000 } = {},
): Promise<AssemblyAiTranscriptResponse> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const res = await fetch(`${BASE_URL}/transcript/${id}`, {
      headers: { Authorization: apiKey },
    });
    if (!res.ok) {
      const bodyText = await res.text();
      throw new Error(`assemblyai poll ${res.status}: ${bodyText.slice(0, 240)}`);
    }
    const data = (await res.json()) as AssemblyAiTranscriptResponse;
    if (data.status === "completed") return data;
    if (data.status === "error") {
      throw new Error(`assemblyai transcription error: ${data.error ?? "unknown"}`);
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
  throw new Error("assemblyai transcription timed out");
}

/**
 * ARCA's AssemblyAI transcription provider.
 * Uploads the raw recording, requests an async transcript with
 * speaker diarization (`speaker_labels: true`), and polls until it's ready.
 * Built for the AssemblyAI Voice Agent Hackathon (lablab.ai, Sep 2026):
 * https://api.assemblyai.com/v2 — Universal speech-to-text + diarization.
 */
export async function transcribeWithAssemblyAI(
  file: File,
  apiKey = assemblyAiKey(),
): Promise<Transcript> {
  if (!apiKey) {
    throw new Error("ASSEMBLYAI_API_KEY is missing.");
  }

  const audioUrl = await uploadAudio(file, apiKey);
  const transcriptId = await requestTranscript(audioUrl, apiKey);
  const data = await pollTranscript(transcriptId, apiKey);

  const rawUtterances = Array.isArray(data.utterances) ? data.utterances : [];
  const speakerOrder = new Map<string, number>();

  const segments: TranscriptSegment[] = rawUtterances
    .map((u, index) => {
      const speaker = (u.speaker || `speaker_${index}`).trim();
      if (!speakerOrder.has(speaker)) speakerOrder.set(speaker, speakerOrder.size);
      return {
        speaker,
        speakerLabel: resolveSpeakerLabel(speaker, speakerOrder),
        text: (u.text ?? "").trim(),
        startMs: Math.max(0, Math.round(u.start ?? 0)),
        endMs: Math.max(0, Math.round(u.end ?? 0)),
      };
    })
    .filter((seg) => seg.text.length > 0);

  if (segments.length === 0 && data.text?.trim()) {
    speakerOrder.set("speaker_0", 0);
    segments.push({
      speaker: "speaker_0",
      speakerLabel: "Speaker 1",
      text: data.text.trim(),
      startMs: 0,
      endMs: Math.round((data.audio_duration ?? 0) * 1000),
    });
  }

  const speakerMap = new Map<string, { segmentCount: number; talkTimeSec: number }>();
  for (const seg of segments) {
    const duration = Math.max(0, (seg.endMs - seg.startMs) / 1000);
    const existing = speakerMap.get(seg.speaker);
    if (existing) {
      existing.segmentCount += 1;
      existing.talkTimeSec += duration;
    } else {
      speakerMap.set(seg.speaker, { segmentCount: 1, talkTimeSec: duration });
    }
  }

  const speakers: SpeakerSummary[] = Array.from(speakerOrder.entries())
    .sort((a, b) => a[1] - b[1])
    .map(([speakerId]) => {
      const stats = speakerMap.get(speakerId) ?? { segmentCount: 0, talkTimeSec: 0 };
      return {
        speaker: speakerId,
        speakerLabel: resolveSpeakerLabel(speakerId, speakerOrder),
        segmentCount: stats.segmentCount,
        talkTimeSec: Math.round(stats.talkTimeSec * 10) / 10,
      };
    });

  const durationSec = Number.isFinite(data.audio_duration)
    ? Math.round(data.audio_duration ?? 0)
    : Math.round(Math.max(0, ...segments.map((seg) => seg.endMs)) / 1000);

  return {
    provider: "assemblyai",
    language: data.language_code ?? "auto",
    durationSec,
    fullText: segments.map((s) => `${s.speakerLabel}: ${s.text}`).join("\n"),
    segments,
    speakerCount: speakerOrder.size,
    speakers,
  };
}
