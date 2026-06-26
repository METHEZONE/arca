import type { Transcript, TranscriptSegment, SpeakerSummary } from "@/lib/types";
import { elevenLabsKey, elevenLabsModel } from "@/lib/config";

// ---------------------------------------------------------------------------
// ElevenLabs Scribe response types
// ---------------------------------------------------------------------------

type ElevenLabsWord = {
  text: string;
  start: number;
  end: number;
  type: "word" | "spacing" | "audio_event";
  speaker_id?: string;
};

type ElevenLabsResponse = {
  language_code: string;
  language_probability: number;
  text: string;
  words: ElevenLabsWord[];
};

// ---------------------------------------------------------------------------
// Demo transcript (no API key)
// ---------------------------------------------------------------------------

function buildDemoTranscript(): Transcript {
  type RawSeg = { speaker: string; speakerLabel: string; text: string; startMs: number; endMs: number };

  const raw: RawSeg[] = [
    {
      speaker: "speaker_0",
      speakerLabel: "Speaker 1",
      text: "Let's start the ARCA product planning session. First, please share progress on the automatic recording-to-notes workflow.",
      startMs: 0,
      endMs: 12000,
    },
    {
      speaker: "speaker_1",
      speakerLabel: "Speaker 2",
      text: "The ElevenLabs Scribe integration is working, and speaker separation looks strong. Accuracy drops in noisy environments, so I am testing a preprocessing filter.",
      startMs: 12500,
      endMs: 28000,
    },
    {
      speaker: "speaker_2",
      speakerLabel: "Speaker 3",
      text: "For preprocessing, have we checked the WebRTC noise cancellation library? It worked well in a previous project.",
      startMs: 28500,
      endMs: 40000,
    },
    {
      speaker: "speaker_1",
      speakerLabel: "Speaker 2",
      text: "Yes, I know that library. I will prototype it this sprint and share comparison results by next Thursday.",
      startMs: 40500,
      endMs: 52000,
    },
    {
      speaker: "speaker_0",
      speakerLabel: "Speaker 1",
      text: "Good. Next agenda item: share user test results for ARCA's second-brain value proposition, turning recordings into notes and action plans.",
      startMs: 52500,
      endMs: 66000,
    },
    {
      speaker: "speaker_2",
      speakerLabel: "Speaker 3",
      text: "We tested with fifteen beta users last week. Satisfaction was high, and the most common request was assigning owners automatically to generated action items.",
      startMs: 66500,
      endMs: 84000,
    },
    {
      speaker: "speaker_1",
      speakerLabel: "Speaker 2",
      text: "If we pre-register speaker names, we can map action items to owners. I will write a Claude prompt spec this week.",
      startMs: 84500,
      endMs: 99000,
    },
    {
      speaker: "speaker_0",
      speakerLabel: "Speaker 1",
      text: "Great. Once that spec is ready, we will add it to the next sprint plan. What is the status of the Notion connector?",
      startMs: 99500,
      endMs: 110000,
    },
    {
      speaker: "speaker_2",
      speakerLabel: "Speaker 3",
      text: "The Notion API connector is about seventy percent complete. Page creation works, but relation property mapping still needs cleanup. I can finish it by Friday.",
      startMs: 110500,
      endMs: 126000,
    },
    {
      speaker: "speaker_0",
      speakerLabel: "Speaker 1",
      text: "Summary: noise cancellation prototype results by next Thursday, speaker-to-owner mapping spec this week, and Notion connector completion by Friday.",
      startMs: 126500,
      endMs: 144000,
    },
  ];

  const segments: TranscriptSegment[] = raw.map((r) => ({
    speaker: r.speaker,
    speakerLabel: r.speakerLabel,
    text: r.text,
    startMs: r.startMs,
    endMs: r.endMs,
  }));

  const speakerMap = new Map<string, { label: string; segmentCount: number; talkTimeSec: number }>();
  for (const seg of segments) {
    const existing = speakerMap.get(seg.speaker);
    const duration = (seg.endMs - seg.startMs) / 1000;
    if (existing) {
      existing.segmentCount += 1;
      existing.talkTimeSec += duration;
    } else {
      speakerMap.set(seg.speaker, {
        label: seg.speakerLabel,
        segmentCount: 1,
        talkTimeSec: duration,
      });
    }
  }

  const speakers: SpeakerSummary[] = Array.from(speakerMap.entries()).map(([speaker, val]) => ({
    speaker,
    speakerLabel: val.label,
    segmentCount: val.segmentCount,
    talkTimeSec: Math.round(val.talkTimeSec * 10) / 10,
  }));

  const lastSeg = segments[segments.length - 1];
  const durationSec = Math.round(lastSeg.endMs / 1000);

  const fullText = segments.map((s) => `${s.speakerLabel}: ${s.text}`).join("\n");

  return {
    provider: "demo",
    language: "en",
    durationSec,
    fullText,
    segments,
    speakerCount: speakerMap.size,
    speakers,
    warning: "ELEVENLABS_API_KEY is missing, so ARCA used a demo transcript.",
  };
}

// ---------------------------------------------------------------------------
// Live transcription via ElevenLabs Scribe
// ---------------------------------------------------------------------------

function resolveSpeakerLabel(speakerId: string, order: Map<string, number>): string {
  const n = order.get(speakerId);
  if (n === undefined) return "Speaker 1";
  return `Speaker ${n + 1}`;
}

async function transcribeLive(file: File, apiKey: string): Promise<Transcript> {
  const form = new FormData();
  form.append("model_id", elevenLabsModel());
  form.append("file", file);
  form.append("diarize", "true");
  form.append("timestamps_granularity", "word");
  form.append("tag_audio_events", "false");

  const res = await fetch("https://api.elevenlabs.io/v1/speech-to-text", {
    method: "POST",
    headers: { "xi-api-key": apiKey },
    body: form,
  });

  if (!res.ok) {
    const bodyText = await res.text();
    throw new Error(`elevenlabs ${res.status}: ${bodyText.slice(0, 240)}`);
  }

  const data = (await res.json()) as ElevenLabsResponse;
  const words = data.words ?? [];

  // Build segments by grouping consecutive words with the same speaker_id.
  // Non-"word" typed entries are included in text but don't trigger speaker splits.
  const speakerOrder = new Map<string, number>(); // speaker_id → 0-based appearance order

  type MutableSegment = {
    speaker: string;
    startSec: number;
    endSec: number;
    textParts: string[];
  };

  const rawSegments: MutableSegment[] = [];
  let current: MutableSegment | null = null;

  for (const w of words) {
    const speakerId = w.speaker_id ?? "speaker_0";

    // Register speaker order on first word-type encounter
    if (w.type === "word" && !speakerOrder.has(speakerId)) {
      speakerOrder.set(speakerId, speakerOrder.size);
    }

    const isNewSpeaker = w.type === "word" && (current === null || speakerId !== current.speaker);

    if (isNewSpeaker) {
      if (current !== null) rawSegments.push(current);
      current = {
        speaker: speakerId,
        startSec: w.start,
        endSec: w.end,
        textParts: [w.text],
      };
    } else if (current !== null) {
      current.textParts.push(w.text);
      if (w.type === "word") {
        current.endSec = w.end;
      }
    }
  }
  if (current !== null) rawSegments.push(current);

  const segments: TranscriptSegment[] = rawSegments.map((seg) => ({
    speaker: seg.speaker,
    speakerLabel: resolveSpeakerLabel(seg.speaker, speakerOrder),
    text: seg.textParts.join("").trim(),
    startMs: Math.round(seg.startSec * 1000),
    endMs: Math.round(seg.endSec * 1000),
  }));

  // Speaker rollup
  const speakerMap = new Map<string, { segmentCount: number; talkTimeSec: number }>();
  for (const seg of segments) {
    const duration = (seg.endMs - seg.startMs) / 1000;
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

  const lastWordEnd = words.filter((w) => w.type === "word").at(-1)?.end ?? 0;
  const durationSec = Math.round(lastWordEnd);

  const fullText = segments.map((s) => `${s.speakerLabel}: ${s.text}`).join("\n");

  return {
    provider: "elevenlabs",
    language: data.language_code,
    durationSec,
    fullText,
    segments,
    speakerCount: speakerOrder.size,
    speakers,
  };
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

export async function transcribe(file: File): Promise<Transcript> {
  const key = elevenLabsKey();
  if (!key) return buildDemoTranscript();
  return transcribeLive(file, key);
}
