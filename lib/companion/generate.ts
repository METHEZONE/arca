// Deterministic companion generator for ARCA OS onboarding.
// Pure + dependency-free so it can run on both client and server.
// Same CompanyProfile (+ salt) always hatches the same companion;
// "다시 뽑기" just bumps the salt.

export type IndustryKey =
  | "bio"
  | "software"
  | "hardware"
  | "creative"
  | "commerce"
  | "finance"
  | "education"
  | "etc";

export type PaceKey = "swift" | "steady" | "careful";
export type ToneKey = "formal" | "warm" | "plain";
export type FocusKey = "morning" | "afternoon" | "night" | "wild";
export type ToolKey = "slack" | "gmail" | "notion" | "obsidian" | "calendar" | "github";

export interface CompanyProfile {
  company: string;
  industry: IndustryKey;
  pace: PaceKey;
  tone: ToneKey;
  focus: FocusKey;
  tools: ToolKey[];
}

export type EarVariant = "none" | "nub" | "point";
export type AntennaVariant = "dot" | "leaf" | "star" | "spark" | "coin" | "shield" | "flag";
export type EyeVariant = "tall" | "round" | "wide";
export type MouthVariant = "none" | "smile" | "cat" | "line";
export type GemShape = "diamond" | "round" | "leaf" | "star" | "square";

export interface CompanionLook {
  headRx: number;
  headW: number;
  headH: number;
  ear: EarVariant;
  antenna: AntennaVariant;
  eye: EyeVariant;
  mouth: MouthVariant;
  cheeks: boolean;
  freckles: number;
  accent: string;
  eyeTop: string;
  eyeMid: string;
  eyeGlow: string;
  bodyTop: string;
  bodyBottom: string;
  strokeCol: string;
  gem: GemShape;
}

export interface CompanionSpec {
  seed: number;
  name: string;
  nameCandidates: string[];
  archetype: string;
  traits: [string, string, string];
  voiceLine: string;
  delegations: string[];
  greeting: string;
  look: CompanionLook;
}

/* ------------------------------ PRNG ------------------------------ */

function hashString(str: string): number {
  let h = 1779033703 ^ str.length;
  for (let i = 0; i < str.length; i++) {
    h = Math.imul(h ^ str.charCodeAt(i), 3432918353);
    h = (h << 13) | (h >>> 19);
  }
  h = Math.imul(h ^ (h >>> 16), 2246822507);
  h = Math.imul(h ^ (h >>> 13), 3266489909);
  return (h ^= h >>> 16) >>> 0;
}

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function pick<T>(rnd: () => number, arr: readonly T[]): T {
  return arr[Math.floor(rnd() * arr.length)];
}

/* --------------------------- Vocabulary --------------------------- */

export const INDUSTRIES: Record<
  IndustryKey,
  { label: string; emoji: string; accent: string; antenna: AntennaVariant; gem: GemShape }
> = {
  bio:       { label: "바이오 · 헬스케어",  emoji: "🌿", accent: "#8fd6a8", antenna: "leaf",   gem: "leaf" },
  software:  { label: "소프트웨어 · IT",    emoji: "⌘",  accent: "#b99bff", antenna: "spark",  gem: "diamond" },
  hardware:  { label: "하드웨어 · 제조",    emoji: "⚙",  accent: "#8fb7ff", antenna: "dot",    gem: "square" },
  creative:  { label: "크리에이티브",        emoji: "✦",  accent: "#ff8fb3", antenna: "star",   gem: "star" },
  commerce:  { label: "커머스 · 리테일",    emoji: "◎",  accent: "#ffd34d", antenna: "coin",   gem: "round" },
  finance:   { label: "금융 · 핀테크",      emoji: "▣",  accent: "#5ecfc0", antenna: "shield", gem: "square" },
  education: { label: "교육 · 리서치",      emoji: "▤",  accent: "#9ac8ff", antenna: "flag",   gem: "round" },
  etc:       { label: "그 외 무엇이든",      emoji: "…",  accent: "#ff9a3c", antenna: "dot",    gem: "diamond" },
};

const NAME_HEADS = ["아", "루", "코", "모", "노", "비", "포", "미", "오", "제", "토", "무"] as const;
const NAME_TAILS = ["루", "비", "코", "미", "무", "니", "타", "로", "키", "디", "보", "리"] as const;
const NAME_CAPS = ["", "", "", "", "니", "리", "토", "미"] as const;

const ARCHETYPES: Record<PaceKey, Record<ToneKey, { name: string; traits: [string, string, string] }>> = {
  careful: {
    formal: { name: "집사형 가디언",   traits: ["차분함", "꼼꼼함", "기록광"] },
    warm:   { name: "사서형 단짝",     traits: ["다정함", "신중함", "수집벽"] },
    plain:  { name: "관측자형 파수꾼", traits: ["과묵함", "정확함", "인내심"] },
  },
  steady: {
    formal: { name: "비서실장형",      traits: ["정돈됨", "균형감", "보고 정신"] },
    warm:   { name: "길잡이형 동료",   traits: ["싹싹함", "정리력", "눈치 백단"] },
    plain:  { name: "정찰병형 실무가", traits: ["간결함", "판단력", "실행력"] },
  },
  swift: {
    formal: { name: "의전형 해결사",   traits: ["기민함", "예의 바름", "추진력"] },
    warm:   { name: "탐험가형 친구",   traits: ["호기심", "명랑함", "돌파력"] },
    plain:  { name: "번개형 해결사",   traits: ["속도", "단호함", "집중력"] },
  },
};

const VOICE_LINES: Record<ToneKey, string> = {
  formal: "다녀왔습니다. 자리를 비우신 동안 세 건을 마무리해 두었습니다.",
  warm: "다녀왔어요! 급한 세 건은 제가 처리해뒀고, 나머지는 골라두기만 했어요.",
  plain: "복귀 보고. 3건 처리 완료, 1건은 판단 대기.",
};

const TOOL_DELEGATIONS: Record<ToolKey, string> = {
  slack: "슬랙 저위험 멘션 응대",
  gmail: "확인성 메일 회신",
  notion: "회의록 노션 자동 정리",
  obsidian: "옵시디언 볼트에 기억 적재",
  calendar: "일정 조율 제안",
  github: "이슈 코멘트 요약",
};

export const TOOL_LABELS: Record<ToolKey, string> = {
  slack: "Slack",
  gmail: "Gmail",
  notion: "Notion",
  obsidian: "Obsidian",
  calendar: "Calendar",
  github: "GitHub",
};

export const PACE_LABELS: Record<PaceKey, string> = {
  swift: "바로 실행한다 — 속도가 생명",
  steady: "정리부터 한다 — 기록이 먼저",
  careful: "신중히 검토한다 — 실수는 비싸다",
};

export const TONE_LABELS: Record<ToneKey, string> = {
  formal: "깍듯한 존댓말",
  warm: "친근한 존댓말",
  plain: "짧고 담백하게",
};

export const TONE_SAMPLES: Record<ToneKey, string> = {
  formal: "「확인 후 정리해 회신드리겠습니다.」",
  warm: "「확인해서 정리해둘게요!」",
  plain: "「확인 후 회신드립니다.」",
};

export const FOCUS_LABELS: Record<FocusKey, string> = {
  morning: "아침 — 세상이 조용할 때",
  afternoon: "오후 — 엔진이 데워진 뒤",
  night: "밤 — 방해가 사라진 뒤",
  wild: "불규칙 — 몰입이 오면 그때",
};

/* --------------------------- Validation --------------------------- */

const PACE_KEYS: PaceKey[] = ["swift", "steady", "careful"];
const TONE_KEYS: ToneKey[] = ["formal", "warm", "plain"];
const FOCUS_KEYS: FocusKey[] = ["morning", "afternoon", "night", "wild"];

/** Validate an untrusted profile (API body, localStorage) into a safe
 *  CompanyProfile, or null. Shared by the route and the client restore path
 *  so stale/foreign data falls back to onboarding instead of crashing. */
export function sanitizeProfile(raw: unknown): CompanyProfile | null {
  if (!raw || typeof raw !== "object") return null;
  const p = raw as Record<string, unknown>;
  const company = typeof p.company === "string" ? p.company.trim().slice(0, 60) : "";
  const industry = p.industry as IndustryKey;
  const pace = p.pace as PaceKey;
  const tone = p.tone as ToneKey;
  const focus = p.focus as FocusKey;
  const tools = Array.isArray(p.tools)
    ? (p.tools.filter(
        (t): t is ToolKey => typeof t === "string" && Object.hasOwn(TOOL_LABELS, t),
      ) as ToolKey[])
    : [];
  if (!company || typeof industry !== "string" || !Object.hasOwn(INDUSTRIES, industry)) return null;
  if (!PACE_KEYS.includes(pace) || !TONE_KEYS.includes(tone) || !FOCUS_KEYS.includes(focus)) return null;
  return { company, industry, pace, tone, focus, tools };
}

/* --------------------------- Generation --------------------------- */

const EYE_PALETTES = [
  { top: "#ffe7cc", mid: "#ff9a3c", glow: "#ff7a1a" },
  { top: "#fff1dc", mid: "#ffb26b", glow: "#ff8a2a" },
  { top: "#ffe2c8", mid: "#ff8a5c", glow: "#ff5c1a" },
] as const;

const BODY_PALETTES = [
  { top: "#2a1812", bottom: "#150c07", stroke: "#7a4a2a" },
  { top: "#241410", bottom: "#120a06", stroke: "#6d4126" },
  { top: "#2d1a10", bottom: "#170d08", stroke: "#8a5430" },
] as const;

function firstHangulSyllable(text: string): string | null {
  for (const ch of text) {
    if (/[가-힣]/.test(ch)) return ch;
  }
  return null;
}

function makeName(rnd: () => number): string {
  return pick(rnd, NAME_HEADS) + pick(rnd, NAME_TAILS) + pick(rnd, NAME_CAPS);
}

function makeNameCandidates(rnd: () => number, company: string): string[] {
  const out: string[] = [];
  const companySyllable = firstHangulSyllable(company);
  if (companySyllable && rnd() > 0.4) {
    out.push(companySyllable + pick(rnd, NAME_TAILS));
  }
  while (out.length < 4) {
    const n = makeName(rnd);
    if (!out.includes(n)) out.push(n);
  }
  return out;
}

export function makeGreeting(tone: ToneKey, company: string, name: string): string {
  const c = company || "이 팀";
  switch (tone) {
    case "formal":
      return `처음 뵙겠습니다, ${c}. 저는 ${name}입니다. 이제 이 팀의 ZONE은 제가 지킵니다.`;
    case "warm":
      return `안녕하세요, ${c}! 저는 ${name}이에요. 앞으로 몰입은 제가 지켜드릴게요.`;
    case "plain":
      return `${name}입니다. ${c}의 ZONE, 지금부터 제가 지킵니다.`;
  }
}

export function generateCompanion(profile: CompanyProfile, salt = 0): CompanionSpec {
  const seedInput = [
    profile.company.trim().toLowerCase(),
    profile.industry,
    profile.pace,
    profile.tone,
    profile.focus,
    [...profile.tools].sort().join(","),
    String(salt),
  ].join("|");
  const seed = hashString(seedInput);
  const rnd = mulberry32(seed);

  const industry = INDUSTRIES[profile.industry];
  const eyePal = pick(rnd, EYE_PALETTES);
  const bodyPal = pick(rnd, BODY_PALETTES);

  // Pace shapes the silhouette: careful teams hatch round, patient guardians;
  // swift teams hatch sharper, lighter ones.
  const headRx =
    profile.pace === "careful" ? 50 + Math.floor(rnd() * 12)
    : profile.pace === "steady" ? 42 + Math.floor(rnd() * 10)
    : 32 + Math.floor(rnd() * 10);
  const headW = 140 + Math.floor(rnd() * 16);
  const headH = 128 + Math.floor(rnd() * 18);

  const ear: EarVariant =
    profile.pace === "swift"
      ? pick(rnd, ["point", "point", "nub"] as const)
      : pick(rnd, ["none", "nub", "nub", "point"] as const);

  const eye: EyeVariant =
    profile.pace === "careful"
      ? pick(rnd, ["tall", "round", "round"] as const)
      : pick(rnd, ["tall", "round", "wide"] as const);

  const mouth: MouthVariant =
    profile.tone === "warm"
      ? pick(rnd, ["smile", "cat"] as const)
      : profile.tone === "formal"
        ? pick(rnd, ["none", "line"] as const)
        : pick(rnd, ["line", "none", "cat"] as const);

  const archetype = ARCHETYPES[profile.pace][profile.tone];
  const nameCandidates = makeNameCandidates(rnd, profile.company);
  const name = nameCandidates[0];

  const delegations = [
    "일정 확인 회신",
    "자료 위치 안내",
    ...profile.tools.map((t) => TOOL_DELEGATIONS[t]),
  ].slice(0, 5);

  return {
    seed,
    name,
    nameCandidates,
    archetype: archetype.name,
    traits: archetype.traits,
    voiceLine: VOICE_LINES[profile.tone],
    delegations,
    greeting: makeGreeting(profile.tone, profile.company, name),
    look: {
      headRx,
      headW,
      headH,
      ear,
      antenna: industry.antenna,
      eye,
      mouth,
      cheeks: profile.tone === "warm" ? true : rnd() > 0.6,
      freckles: rnd() > 0.55 ? 1 + Math.floor(rnd() * 3) : 0,
      accent: industry.accent,
      eyeTop: eyePal.top,
      eyeMid: eyePal.mid,
      eyeGlow: eyePal.glow,
      bodyTop: bodyPal.top,
      bodyBottom: bodyPal.bottom,
      strokeCol: bodyPal.stroke,
      gem: industry.gem,
    },
  };
}
