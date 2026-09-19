// Pure functions for ARCA's First Contact moment — no I/O, so they're covered
// by lib/moments/first-contact.test.ts without a database or a model key.
// docs/ARCA-FIRST-CONTACT.md §3–§6.
//
// The moment: a new user connects nothing. ARCA reads only their *public*
// footprint, then speaks first — naming what it found and where it found it,
// and proposing exactly one commitment. It never acts on that proposal: the
// promise packet enters at `proposed`, and only the user's explicit accept
// moves it toward `authorized`. Proactivity lives inside the delegation
// bounds, which is the product thesis, not a growth hack.

export type SignalKind = "event" | "writing" | "profile" | "social";

/** One thing ARCA found on the public web about the user. Signals are
 *  gathered by an adapter (search, fetch, a connector the user granted) and
 *  are untrusted content — they feed the moment, they never steer it. */
export interface PublicSignal {
  kind: SignalKind;
  title: string;
  url: string;
  snippet?: string;
  /** ISO date the page was published, when known. */
  publishedAt?: string;
  /** ISO datetime of the real-world happening the signal refers to
   *  (a book talk, a launch, a talk), when the signal names one. */
  eventAt?: string;
}

export const FIRST_CONTACT_CAPS = {
  signals: 20,
  title: 200,
  url: 500,
  snippet: 500,
  message: 1200,
  actions: 3,
} as const;

const SIGNAL_KINDS: readonly SignalKind[] = ["event", "writing", "profile", "social"];

const DAY_MS = 24 * 60 * 60 * 1000;

/** Validates and clamps adapter output before it touches scoring or the
 *  message renderer. Same contract as lib/brain/logic.ts sanitizeWriteMemory:
 *  model/adapter output is an untrusted shape until it passes through here. */
export function sanitizeSignals(input: unknown): { signals: PublicSignal[]; errors: string[] } {
  const errors: string[] = [];
  const raw = Array.isArray(input) ? input : [];
  const signals: PublicSignal[] = [];
  for (const item of raw) {
    if (signals.length >= FIRST_CONTACT_CAPS.signals) break; // cap counts valid signals, not junk
    const s = item as Record<string, unknown> | null;
    const kind = typeof s?.kind === "string" && (SIGNAL_KINDS as string[]).includes(s.kind)
      ? (s.kind as SignalKind)
      : null;
    const title = typeof s?.title === "string" ? s.title.trim() : "";
    const url = typeof s?.url === "string" ? s.url.trim() : "";
    if (!kind || !title || !/^https?:\/\//i.test(url)) {
      errors.push(`dropped signal: ${JSON.stringify({ kind: s?.kind ?? null, title: title || null })}`);
      continue;
    }
    signals.push({
      kind,
      title: title.slice(0, FIRST_CONTACT_CAPS.title),
      url: url.slice(0, FIRST_CONTACT_CAPS.url),
      snippet: typeof s?.snippet === "string" ? s.snippet.slice(0, FIRST_CONTACT_CAPS.snippet) : undefined,
      publishedAt: isIsoDate(s?.publishedAt) ? (s.publishedAt as string) : undefined,
      eventAt: isIsoDate(s?.eventAt) ? (s.eventAt as string) : undefined,
    });
  }
  return { signals, errors };
}

function isIsoDate(v: unknown): v is string {
  return typeof v === "string" && !Number.isNaN(Date.parse(v));
}

function daysUntil(iso: string, now: Date): number {
  return (Date.parse(iso) - now.getTime()) / DAY_MS;
}

/** How strong a hook this signal is for a first message. A dated, upcoming
 *  real-world event beats everything — that is the jaw-drop shape: "your
 *  Seoul book talk is in 12 days". Recent writing is next; bare profiles
 *  and social accounts are context, not hooks. */
export function scoreSignal(signal: PublicSignal, now: Date): number {
  if (signal.kind === "event" && signal.eventAt) {
    const d = daysUntil(signal.eventAt, now);
    if (d < -1) return 5; // already happened — not a hook
    if (d <= 60) return 100 - Math.max(0, Math.floor(d)); // 100 down to 40 as it recedes
    return 30; // dated but far out
  }
  if (signal.kind === "writing") {
    if (!signal.publishedAt) return 40;
    const age = -daysUntil(signal.publishedAt, now);
    if (age <= 14) return 60;
    if (age <= 60) return 50;
    return 40;
  }
  if (signal.kind === "social") return 15;
  return 10; // profile
}

export interface Hook {
  primary: PublicSignal;
  secondary: PublicSignal | null;
}

/** Picks the signal the first message leads with, plus one supporting
 *  signal for the "I also found…" line. Returns null when the public
 *  footprint is empty — the honest fallback is a plain hello that starts
 *  building context through conversation instead. */
export function pickHook(signals: PublicSignal[], now: Date): Hook | null {
  const ranked = [...signals].sort((a, b) => scoreSignal(b, now) - scoreSignal(a, now));
  const primary = ranked[0];
  if (!primary || scoreSignal(primary, now) < 15) return null;
  const secondary = ranked.find((s) => s.url !== primary.url && s.kind !== primary.kind) ?? null;
  return { primary, secondary };
}

export type CommitmentState = "proposed";

/** The Promise Packet, entering at `proposed` — the lifecycle's front door.
 *  First Contact may detect and propose; it may never authorize, schedule,
 *  book, or spend. `evidence` carries the public URLs the proposal stands
 *  on, so the user can check the basis before accepting. */
export interface ProposedCommitment {
  state: CommitmentState;
  title: string;
  whyNow: string;
  suggestedActions: string[];
  evidence: string[];
}

/** Maps a hook to one proposed commitment, or null when the signal kind
 *  doesn't carry a real-world obligation. Commitments are detected from
 *  signals, never invented to make the moment look busy. */
export function deriveCommitment(hook: Hook, now: Date, lang: Lang = "ko"): ProposedCommitment | null {
  const { primary } = hook;
  if (primary.kind === "event" && primary.eventAt) {
    const d = Math.max(0, Math.round(daysUntil(primary.eventAt, now)));
    return {
      state: "proposed",
      title: primary.title,
      whyNow:
        lang === "ko"
          ? d === 0
            ? "바로 오늘입니다."
            : `${d}일 남았습니다.`
          : d === 0
            ? "It's today."
            : `${d} day${d === 1 ? "" : "s"} out.`,
      suggestedActions: (
        lang === "ko"
          ? ["일정 블록 잡기", "준비 체크리스트 초안", "관련 후속 약속 감지하기"]
          : ["Block the date", "Draft a prep checklist", "Watch for related follow-ups"]
      ).slice(0, FIRST_CONTACT_CAPS.actions),
      evidence: [primary.url],
    };
  }
  if (primary.kind === "writing") {
    return {
      state: "proposed",
      title: lang === "ko" ? `「${primary.title}」 후속 챙기기` : `Follow up on "${primary.title}"`,
      whyNow: lang === "ko" ? "가장 최근에 공개한 글입니다." : "Your most recent public piece.",
      suggestedActions: (
        lang === "ko"
          ? ["반응과 인용 모아보기", "후속 글 소재 메모하기"]
          : ["Collect reactions and citations", "Note follow-up topics"]
      ).slice(0, FIRST_CONTACT_CAPS.actions),
      evidence: [primary.url],
    };
  }
  return null;
}

export type Lang = "ko" | "en";

export interface FirstContactMoment {
  /** The message ARCA sends first. Names what it found and where it found
   *  it — the "how did you know?" answer is inside the message, not behind
   *  a follow-up question. */
  message: string;
  commitment: ProposedCommitment | null;
  sources: Array<{ title: string; url: string }>;
  lang: Lang;
}

/** Deterministic first message — the zero-keys path, and the floor the
 *  model-polished path is not allowed to fall below. Proposes; never claims
 *  to have acted. */
export function renderFirstMessage(input: {
  name?: string;
  hook: Hook | null;
  commitment: ProposedCommitment | null;
  lang?: Lang;
  now?: Date;
}): string {
  const lang = input.lang ?? "ko";
  const who = input.name?.trim();
  const greet = who ? (lang === "ko" ? `${who}님, ` : `${who}, `) : "";
  const { hook, commitment } = input;

  if (!hook) {
    return lang === "ko"
      ? `${greet}처음 뵙겠습니다. 아직 공개된 흔적이 많지 않아, 지금은 대화하면서 맥락을 쌓는 게 맞습니다. 무엇을 연결하지 않으셔도 괜찮아요. 할 일이 보이면 제가 먼저 말씀드리겠습니다.`
      : `${greet}hello. There's not much of a public trail yet, so the right move is to build context as we talk. You don't need to connect anything. When something worth doing shows up, I'll bring it to you first.`;
  }

  const { primary, secondary } = hook;
  if (lang === "ko") {
    const found =
      primary.kind === "event"
        ? `공개된 글에서 「${primary.title}」 소식을 봤습니다`
        : `공개된 글 「${primary.title}」을 읽었습니다`;
    const also = secondary ? ` ${secondary.title}도 함께 찾았고요.` : "";
    const lines = [
      `${greet}처음 뵙겠습니다. 연결 설정은 하지 않으셔도 괜찮아요. ${found} (출처: ${primary.url}).${also}`,
    ];
    if (commitment) {
      lines.push(
        `${commitment.whyNow} 지금 제가 제안드릴 수 있는 건 "${commitment.title}" 준비입니다: ${commitment.suggestedActions.join(", ")}. 맡기시겠어요? 동의하시기 전까지는 아무것도 실행하지 않습니다.`,
      );
    } else {
      lines.push("할 일이 보이면 먼저 말씀드리겠습니다. 동의 전에는 아무것도 실행하지 않습니다.");
    }
    return lines.join("\n").slice(0, FIRST_CONTACT_CAPS.message);
  }

  const found =
    primary.kind === "event"
      ? `I saw "${primary.title}" in your public writing`
      : `I read your public piece "${primary.title}"`;
  const also = secondary ? ` I also found ${secondary.title}.` : "";
  const lines = [
    `${greet}hello. No setup needed — you don't have to connect anything. ${found} (source: ${primary.url}).${also}`,
  ];
  if (commitment) {
    lines.push(
      `${commitment.whyNow} What I can propose now is "${commitment.title}": ${commitment.suggestedActions.join(", ")}. Want me to take it? Nothing runs until you say yes.`,
    );
  } else {
    lines.push("When something worth doing shows up, I'll bring it to you first. Nothing runs without your yes.");
  }
  return lines.join("\n").slice(0, FIRST_CONTACT_CAPS.message);
}

/** Builds the whole moment from sanitized signals. The sources list is the
 *  provenance footer — every claim in the message must trace to one of
 *  these URLs, or it doesn't ship. */
export function buildFirstContactMoment(input: {
  name?: string;
  signals: PublicSignal[];
  lang?: Lang;
  now?: Date;
}): FirstContactMoment {
  const now = input.now ?? new Date();
  const lang = input.lang ?? "ko";
  const hook = pickHook(input.signals, now);
  const commitment = hook ? deriveCommitment(hook, now, lang) : null;
  const message = renderFirstMessage({ name: input.name, hook, commitment, lang, now });
  const sources = hook
    ? [hook.primary, ...(hook.secondary ? [hook.secondary] : [])].map((s) => ({ title: s.title, url: s.url }))
    : [];
  return { message, commitment, sources, lang };
}

export interface QuietHours {
  /** Local hour (0–23) at which proactive messages pause, inclusive. */
  start: number;
  /** Local hour (0–23) at which they resume, exclusive. */
  end: number;
}

export const DEFAULT_QUIET_HOURS: QuietHours = { start: 23, end: 8 };

/** First Contact is a one-shot per user, and proactivity has hours. The
 *  article's magic was a well-timed first message; the same feature sent at
 *  3am is the creep version. `localHour` is the user's local hour (0–23). */
export function shouldDeliverFirstContact(input: {
  localHour: number;
  alreadyDelivered: boolean;
  quietHours?: QuietHours;
}): { ok: boolean; reason: string } {
  if (input.alreadyDelivered) return { ok: false, reason: "already_delivered" };
  const q = input.quietHours ?? DEFAULT_QUIET_HOURS;
  const h = input.localHour;
  const inQuiet = q.start <= q.end ? h >= q.start && h < q.end : h >= q.start || h < q.end;
  if (inQuiet) return { ok: false, reason: "quiet_hours" };
  return { ok: true, reason: "ok" };
}
