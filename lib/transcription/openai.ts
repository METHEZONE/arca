import { openAiKey, openAiTranscriptionModel } from "@/lib/config";
import type { SpeakerSummary, Transcript, TranscriptSegment } from "@/lib/types";

type OpenAiDiarizedSegment = {
  speaker?: string;
  text?: string;
  start?: number;
  end?: number;
};

type OpenAiDiarizedResponse = {
  text?: string;
  language?: string;
  duration?: number;
  segments?: OpenAiDiarizedSegment[];
};

function resolveSpeakerLabel(speakerId: string, order: Map<string, number>): string {
  const explicitName = speakerId.trim();
  if (explicitName && !/^speaker[_\s-]?\d+$/i.test(explicitName)) return explicitName;
  const n = order.get(speakerId);
  return `Speaker ${(n ?? 0) + 1}`;
}

function toMs(seconds: number | undefined): number {
  if (!Number.isFinite(seconds)) return 0;
  return Math.max(0, Math.round((seconds ?? 0) * 1000));
}

export async function transcribeWithOpenAI(
  file: File,
  apiKey = openAiKey(),
): Promise<Transcript> {
  if (!apiKey) {
    throw new Error("OPENAI_API_KEY is missing.");
  }

  const form = new FormData();
  form.append("file", file);
  form.append("model", openAiTranscriptionModel());
  form.append("response_format", "diarized_json");
  form.append("chunking_strategy", "auto");

  const res = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}` },
    body: form,
  });

  if (!res.ok) {
    const bodyText = await res.text();
    throw new Error(`openai ${res.status}: ${bodyText.slice(0, 240)}`);
  }

  const data = (await res.json()) as OpenAiDiarizedResponse;
  const rawSegments = Array.isArray(data.segments) ? data.segments : [];
  const speakerOrder = new Map<string, number>();

  const segments: TranscriptSegment[] = rawSegments
    .map((seg, index) => {
      const speaker = (seg.speaker || `speaker_${index}`).trim();
      if (!speakerOrder.has(speaker)) speakerOrder.set(speaker, speakerOrder.size);
      return {
        speaker,
        speakerLabel: resolveSpeakerLabel(speaker, speakerOrder),
        text: (seg.text ?? "").trim(),
        startMs: toMs(seg.start),
        endMs: toMs(seg.end),
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
      endMs: toMs(data.duration),
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

  const durationSec =
    Number.isFinite(data.duration) && data.duration
      ? Math.round(data.duration)
      : Math.round(Math.max(0, ...segments.map((seg) => seg.endMs)) / 1000);

  return {
    provider: "openai",
    language: data.language ?? "auto",
    durationSec,
    fullText: segments.map((s) => `${s.speakerLabel}: ${s.text}`).join("\n"),
    segments,
    speakerCount: speakerOrder.size,
    speakers,
  };
}
