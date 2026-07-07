// Showcase memories — crafted second-brain entries that make a fresh deploy
// feel alive. They appear alongside real memories (until deleted), can be
// opened, edited (materialized to disk on first write), and deleted
// (tombstoned so they stay gone). Disable entirely with ARCA_SHOWCASE=off.
//
// The content deliberately mirrors the /arca landing's recall demos (founding
// price decision, BZCF ring meeting) so landing → product reads as one story.

import type {
  ActionItem,
  Decision,
  Memory,
  SpeakerSummary,
  Transcript,
  TranscriptSegment,
} from "@/lib/types";

const SHOWCASE_PREFIX = "showcase-";

export function isShowcaseId(id: string): boolean {
  return id.startsWith(SHOWCASE_PREFIX);
}

export function showcaseEnabled(): boolean {
  return process.env.ARCA_SHOWCASE !== "off";
}

/* ---------------------------------------------------------------- *
 * Builders — keep the crafted data below readable
 * ---------------------------------------------------------------- */

type Line = [speaker: string, text: string];

function buildTranscript(lines: Line[], language = "en"): Transcript {
  const speakerIds = new Map<string, string>();
  const segments: TranscriptSegment[] = [];
  let cursor = 0;

  for (const [label, text] of lines) {
    if (!speakerIds.has(label)) speakerIds.set(label, `speaker_${speakerIds.size}`);
    const startMs = cursor;
    // ~15 chars/sec speaking pace + a beat between turns.
    const durMs = Math.max(1800, Math.round((text.length / 15) * 1000));
    cursor = startMs + durMs + 700;
    segments.push({
      speaker: speakerIds.get(label)!,
      speakerLabel: label,
      text,
      startMs,
      endMs: startMs + durMs,
    });
  }

  const speakers: SpeakerSummary[] = [...speakerIds.entries()].map(([label, id]) => {
    const own = segments.filter((s) => s.speaker === id);
    return {
      speaker: id,
      speakerLabel: label,
      segmentCount: own.length,
      talkTimeSec: Math.round(own.reduce((t, s) => t + (s.endMs - s.startMs), 0) / 1000),
    };
  });

  return {
    provider: "demo",
    language,
    durationSec: Math.round(cursor / 1000),
    fullText: lines.map(([label, text]) => `${label}: ${text}`).join("\n"),
    segments,
    speakerCount: speakers.length,
    speakers,
  };
}

let actionSeq = 0;
function action(
  title: string,
  owner: string,
  priority: ActionItem["priority"],
  status: ActionItem["status"],
  sourceQuote?: string,
  due?: string,
): ActionItem {
  actionSeq += 1;
  return { id: `showcase-action-${actionSeq}`, title, owner, due, priority, status, sourceQuote };
}

function decision(text: string, sourceQuote?: string): Decision {
  return { text, sourceQuote };
}

type Crafted = {
  id: string;
  createdAt: string;
  sourceFileName: string;
  tags: string[];
  lines: Line[];
  analysis: Omit<Memory["analysis"], "provider">;
};

function craft(c: Crafted): Memory {
  const transcript = buildTranscript(c.lines);
  return {
    id: c.id,
    createdAt: c.createdAt,
    updatedAt: c.createdAt,
    sourceFileName: c.sourceFileName,
    durationSec: transcript.durationSec,
    speakerCount: transcript.speakerCount,
    tags: [...c.tags, "showcase"],
    transcript,
    analysis: { provider: "demo", ...c.analysis },
    integrations: [],
    isDemo: true,
  };
}

/* ---------------------------------------------------------------- *
 * The crafted memories
 * ---------------------------------------------------------------- */

const WELCOME = craft({
  id: "showcase-welcome",
  createdAt: "2026-07-07T09:12:00.000Z",
  sourceFileName: "welcome-to-arca.m4a",
  tags: ["onboarding"],
  lines: [
    ["ARCA", "Hi. I'm ARCA — your second self. This card is a memory: every recording you give me becomes one of these."],
    ["ARCA", "Drop in any meeting audio, or hit record and just talk. I transcribe it, split the speakers, and pull out what actually matters."],
    ["ARCA", "Each memory keeps the transcript, a grounded summary, the decisions you made, and an action plan you can check off."],
    ["ARCA", "When you connect Obsidian, Notion, or Slack, I file every memory into your real knowledge surfaces automatically."],
    ["ARCA", "These first memories are examples from my world — open them, poke around, delete them when you're done. Then make your own."],
  ],
  analysis: {
    title: "Welcome to ARCA — start here",
    summary:
      "ARCA introduces itself: recordings become memories with speaker-separated transcripts, grounded summaries, decisions, and an executable action plan — filed automatically into Obsidian, Notion, or Slack once connected. The showcase memories are safe to explore and delete.",
    highlights: [
      "Every recording becomes a memory: transcript + summary + decisions + actions",
      "Works with zero keys in demo mode; each live layer activates with its API key",
      "Connectors file memories into Obsidian, Notion, and Slack automatically",
    ],
    topics: ["Onboarding", "How ARCA works"],
    decisions: [],
    actionItems: [
      action("Record or upload your first memory", "You", "high", "todo", "Drop in any meeting audio, or hit record and just talk."),
      action("Open a showcase memory and read the transcript", "You", "medium", "todo"),
      action("Connect one destination — Obsidian, Notion, or Slack", "You", "medium", "todo", "I file every memory into your real knowledge surfaces automatically."),
    ],
    followups: [],
    openQuestions: [],
  },
});

const PRICING = craft({
  id: "showcase-pricing-standup",
  createdAt: "2026-06-30T01:30:00.000Z",
  sourceFileName: "tuesday-standup.m4a",
  tags: ["meeting", "pricing"],
  lines: [
    ["Min", "Okay, last thing — pricing. We keep going back and forth, let's lock it today."],
    ["Jane", "The waitlist replies keep saying the same thing: nineteen is a no-brainer, ninety-nine needs a champion inside the team."],
    ["Min", "Then Second Self stays at nineteen a month. And I want founding members locked at that price for life — early believers should never get a price hike."],
    ["Jane", "Agreed. It also gives every launch post a real hook: founding price, locked forever, limited to the first thousand."],
    ["Leo", "Teams at ninety-nine per seat is fine for now. Nobody buys that from a landing page anyway — it closes in demos."],
    ["Min", "Locked. Nineteen founding for life, ninety-nine per seat for ZONE teams, free tier keeps one companion and fifty delegations."],
    ["Jane", "I'll update the landing pricing section and the waitlist email sequence tonight."],
  ],
  analysis: {
    title: "Pricing standup — founding price locked",
    summary:
      "The team locked ARCA's pricing: Second Self stays at $19/mo with founding members locked for life, ZONE for Teams at $99/seat closed through demos, and the free Companion tier keeps one companion with 50 delegations a month. Jane updates the landing and email sequence.",
    highlights: [
      "Founding members lock $19/mo for life — capped at the first 1,000",
      "$99/seat Teams tier closes in demos, not from the landing page",
      "Free tier: one companion, 50 delegations a month",
    ],
    topics: ["Pricing", "Launch", "Positioning"],
    decisions: [
      decision("Second Self is $19/mo; founding members keep that price for life.", "I want founding members locked at that price for life — early believers should never get a price hike."),
      decision("ZONE for Teams stays $99/seat and is sold through demos.", "Nobody buys that from a landing page anyway — it closes in demos."),
      decision("Free tier keeps one companion and 50 delegations a month.", "free tier keeps one companion and fifty delegations"),
    ],
    actionItems: [
      action("Update landing pricing section with founding-price lock", "Jane", "high", "done", "I'll update the landing pricing section and the waitlist email sequence tonight."),
      action("Rewrite waitlist email sequence around the founding hook", "Jane", "high", "doing"),
      action("Add first-1,000 founding counter to the waitlist flow", "Leo", "medium", "todo", "founding price, locked forever, limited to the first thousand"),
    ],
    followups: [
      "To waitlist: Founding pricing is locked — $19/mo for life for the first 1,000 members. You're in line.",
    ],
    openQuestions: ["When do we publish the founding-member counter publicly?"],
  },
});

const BZCF = craft({
  id: "showcase-bzcf-ring",
  createdAt: "2026-07-04T08:40:00.000Z",
  sourceFileName: "arca-ring-bzcf.wav",
  tags: ["hardware", "device:arca-ring", "networking"],
  lines: [
    ["Min", "Voice note after BZCF demo day. Three people tapped the ring today — logging them before I forget the faces."],
    ["Min", "Kim Chulsoo, hardware investor. We talked AI recorders and he asked for the deck. He liked that the ring is the memory, not a business card."],
    ["Min", "Second, Sarah from a Series A devtools startup — she wants ARCA for her team's standups. Said the words 'we lose every decision within a week.'"],
    ["Min", "Third, a Yonsei junior building agents. Sharp. Possible first community hire when we open that up."],
    ["Min", "Follow-ups: deck to Chulsoo tomorrow morning, team pilot call with Sarah, and add all three to the second brain with faces and context."],
  ],
  analysis: {
    title: "BZCF demo day — three ring connections",
    summary:
      "Min logged three connections from BZCF demo day, captured through the ARCA Ring: hardware investor Kim Chulsoo (wants the deck), Sarah from a devtools startup (wants a team pilot for standups), and a Yonsei junior building agents (possible community hire). Follow-ups are queued for all three.",
    highlights: [
      "Kim Chulsoo — hardware investor, asked for the deck after the ring tap",
      "Sarah — devtools startup, 'we lose every decision within a week', wants a pilot",
      "Yonsei junior building agents — possible first community hire",
    ],
    topics: ["ARCA Ring", "Networking", "Investors"],
    decisions: [
      decision("Send the deck to Kim Chulsoo, then follow up in person.", "deck to Chulsoo tomorrow morning"),
    ],
    actionItems: [
      action("Send deck to Kim Chulsoo", "Min", "high", "done", "deck to Chulsoo tomorrow morning", "2026-07-05"),
      action("Schedule team pilot call with Sarah", "Min", "high", "todo", "team pilot call with Sarah"),
      action("Add all three connections to the second brain with context", "ARCA", "medium", "done", "add all three to the second brain with faces and context"),
    ],
    followups: [
      "To Chulsoo: Great meeting you at BZCF — here's the deck. The ring you tapped is the memory layer in hardware form.",
      "To Sarah: You said 'we lose every decision within a week' — that's exactly the loop ARCA closes. 20 minutes this week?",
    ],
    openQuestions: ["When does the community hiring track open?"],
  },
});

const HYUNDAI = craft({
  id: "showcase-hyundai-sprint",
  createdAt: "2026-06-27T05:00:00.000Z",
  sourceFileName: "zer01ne-sprint-debrief.mp3",
  tags: ["meeting", "zer01ne"],
  lines: [
    ["Min", "ZER01NE debrief. The ten-minute slot is confirmed, so the whole pitch becomes one live demo. No slides walls, no feature tour."],
    ["Jane", "Structure it as one loop then: speak a delegation, watch ARCA transcribe, decide, file, and report back — all inside the ten minutes."],
    ["Min", "Exactly. 'arca it — wrap up this meeting' on stage, and the recap lands in Notion and Slack before I finish talking."],
    ["Leo", "Risk is stage Wi-Fi. I'll prepare the offline fallback so the loop still completes locally if the network dies."],
    ["Jane", "I'll cut the deck to eight frames — worldview, loop, wedge, ask. The demo carries everything else."],
    ["Min", "Decision then: live loop over slides, offline fallback ready, and we close on the companion worldview — arc, archive, ark."],
  ],
  analysis: {
    title: "ZER01NE sprint debrief — pitch becomes one live loop",
    summary:
      "The Hyundai ZER01NE 10-minute pitch was redesigned around a single live demo: speak 'arca it — wrap up this meeting' on stage and let the full loop — transcribe, decide, file, report — complete before the talk ends. Leo prepares an offline fallback for stage Wi-Fi; Jane cuts the deck to eight frames.",
    highlights: [
      "Pitch = one live delegation loop, completed on stage inside 10 minutes",
      "Offline fallback keeps the loop alive if stage Wi-Fi dies",
      "Deck reduced to eight frames: worldview, loop, wedge, ask",
    ],
    topics: ["ZER01NE", "Pitch", "Live demo"],
    decisions: [
      decision("The pitch is a live delegation loop, not a slide tour.", "the whole pitch becomes one live demo"),
      decision("Prepare an offline fallback for the on-stage loop.", "I'll prepare the offline fallback so the loop still completes locally if the network dies."),
      decision("Close on the companion worldview: arc, archive, ark.", "we close on the companion worldview — arc, archive, ark"),
    ],
    actionItems: [
      action("Build offline fallback for the live loop", "Leo", "high", "done", "I'll prepare the offline fallback so the loop still completes locally if the network dies."),
      action("Cut deck to eight frames", "Jane", "high", "done", "I'll cut the deck to eight frames — worldview, loop, wedge, ask."),
      action("Rehearse the 10-minute loop end to end, twice", "Min", "high", "doing"),
    ],
    followups: [],
    openQuestions: ["Do we show the hardware ring on stage or keep it software-only?"],
  },
});

const SHOWCASE: Memory[] = [WELCOME, BZCF, PRICING, HYUNDAI];

/* ---------------------------------------------------------------- *
 * Accessors
 * ---------------------------------------------------------------- */

export function showcaseMemories(): Memory[] {
  if (!showcaseEnabled()) return [];
  // Deep-clone so callers can't mutate the module singletons.
  return SHOWCASE.map((m) => structuredClone(m));
}

export function getShowcaseMemory(id: string): Memory | null {
  if (!showcaseEnabled()) return null;
  const found = SHOWCASE.find((m) => m.id === id);
  return found ? structuredClone(found) : null;
}
