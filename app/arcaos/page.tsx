"use client";

// ARCA OS — onboarding hatchery + companion dashboard.
// Scene 1: the core interviews the team (company context accumulates in a ledger).
// Scene 2: the context compresses and a bespoke companion hatches from it.
// Scene 3: the companion becomes the face of ARCA OS — synced capture across
// devices, autonomously handled items (always signed), and the decisions that
// genuinely need the user, resolved as game-style choices.
// Works with zero keys; with ANTHROPIC_API_KEY the hatch persona goes live.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";

import {
  generateCompanion,
  makeGreeting,
  sanitizeProfile,
  INDUSTRIES,
  PACE_LABELS,
  TONE_LABELS,
  TONE_SAMPLES,
  FOCUS_LABELS,
  TOOL_LABELS,
  type CompanyProfile,
  type CompanionSpec,
  type IndustryKey,
  type PaceKey,
  type ToneKey,
  type FocusKey,
  type ToolKey,
} from "@/lib/companion/generate";
import { GeneratedCompanion, CoreEgg, type CompanionMood } from "./Companion";
import "./arcaos.css";

/* ── Motion ─────────────────────────────────────────────────── */

const EASE = [0.22, 1, 0.36, 1] as const;

const sceneV = {
  hidden: { opacity: 0, y: 16 },
  show: { opacity: 1, y: 0, transition: { duration: 0.5, ease: EASE } },
  exit: { opacity: 0, y: -12, transition: { duration: 0.28, ease: EASE } },
};

const riseV = {
  hidden: { opacity: 0, y: 12 },
  show: { opacity: 1, y: 0, transition: { duration: 0.45, ease: EASE } },
};

const staggerV = (delay = 0.05, gap = 0.08) => ({
  hidden: {},
  show: { transition: { delayChildren: delay, staggerChildren: gap } },
});

/* ── Companion speech ───────────────────────────────────────── */

const SPEECH_IDLE: Record<ToneKey, string> = {
  formal: "무엇이든 맡겨주세요. 「arca it」 한마디면 제가 이어받습니다.",
  warm: "필요한 게 있으면 「arca it」이라고만 해주세요. 제가 이어받을게요!",
  plain: "「arca it」 — 그 한마디면 됩니다.",
};

const SPEECH_GUARD: Record<ToneKey, string> = {
  formal: "ZONE을 사수하는 중입니다. 들어오는 것은 제가 먼저 봅니다.",
  warm: "지금은 제가 문 앞을 지키고 있어요. 몰입만 하세요!",
  plain: "가드 중. 방해는 제가 먼저 봅니다.",
};

const SPEECH_RESOLVED: Record<ToneKey, string> = {
  formal: "결정 감사합니다. 바로 반영해 두었습니다.",
  warm: "좋은 선택이에요! 바로 반영해둘게요.",
  plain: "반영 완료.",
};

/* ── OS demo data (hand-authored, company-interpolated) ─────── */

interface OsDecision {
  id: string;
  source: string;
  from: string;
  title: string;
  question: string;
  draft: string;
  options: { id: string; label: string }[];
  recommendedId: string;
  rationale: string;
  risk: "low" | "high";
}

function buildOsData(company: string, signName: string) {
  const sign = `– ${signName}'s ARCA`;
  return {
    sync: [
      { device: "Watch", icon: "⌚", time: "10:32", head: "주간 제품 싱크 캡처", sub: "버튼 한 번 · 34분 녹음" },
      { device: "iPhone", icon: "📱", time: "10:41", head: "이동 중 전사 완료", sub: "화자 3명 분리 · 한국어" },
      { device: "Mac", icon: "💻", time: "10:43", head: "액션 5건 생성", sub: "2건 자율 처리 · 2건 판단 대기" },
    ],
    memory: {
      title: "주간 제품 싱크",
      time: "10:32 · 34분 · 화자 3명",
      summary:
        "데모 빌드 프리즈와 리포트 첫 화면 IA를 확정했다. 하드웨어는 데모 소품으로 유지하고, 자율 회신 서명 정책은 변경 없이 간다.",
      topics: ["데모 빌드", "리포트 IA", "서명 정책"],
      speakers: [
        { name: "민 · 대표", talk: "12분" },
        { name: "개발 리드", talk: "9분" },
        { name: "디자인 리드", talk: "6분" },
      ],
      segments: [
        { speaker: "민", text: "이번 주 안에 데모 빌드 잠그고, 하드웨어는 데모 소품으로만 갑니다." },
        { speaker: "개발 리드", text: "그러면 전사 파이프라인은 지금 브랜치로 프리즈할게요. 서명 문구는 그대로 두고요." },
        { speaker: "디자인 리드", text: "리포트 첫 화면 통계는 조용하게 한 줄로만 보여주는 걸로 확정할게요." },
      ],
      actions: [
        { title: "회의록 노션 정리", owner: "ARCA", done: true },
        { title: "참석자 요약 공유 초안 준비", owner: "ARCA", done: true },
        { title: "데모 빌드 프리즈", owner: "개발 리드", done: false },
        { title: "리포트 첫 화면 시안", owner: "디자인 리드", done: false },
        { title: "한빛 단가 회신 검토", owner: "민", done: false },
      ],
    },
    handled: [
      { icon: "#", from: "디자인 리드 · Slack", title: "회의록 위치 문의", action: `노션 링크 안내 회신 ${sign}`, badge: "HANDLE" },
      { icon: "#", from: "팀 동료 · Slack", title: "내일 데모 리허설 시간 확인", action: `일정 확인 답장 발송 ${sign}`, badge: "HANDLE" },
      { icon: "#", from: "#general · Slack", title: "전사 워크숍 공지 FYI", action: "요약해서 보관 · 조용히", badge: "DEFER" },
    ],
    decisions: [
      {
        id: "d-finance",
        source: "Slack",
        from: "재무팀 김과장",
        title: "재무 미팅 시간 변경 요청",
        question: "“재무 미팅 시간 변경” — 어떻게 할까요?",
        draft: `안녕하세요, 김과장님. 목요일 14시로 옮기는 것 가능합니다. 캘린더 초대는 업데이트해 두겠습니다.\n${sign}`,
        options: [
          { id: "send", label: "ARCA 추천안 보내기" },
          { id: "draft", label: "초안만 열기" },
          { id: "self", label: "내가 직접 / 나중에" },
        ],
        recommendedId: "send",
        rationale: "참석자 전원의 캘린더가 비어 있어, ARCA가 맥락을 보고 권장한 처리입니다.",
        risk: "low",
      },
      {
        id: "d-pricing",
        source: "Gmail",
        from: "거래처 (주)한빛",
        title: "긴급 단가 재확인 요청",
        question: "“긴급 단가 재확인” — 어떻게 할까요?",
        draft: `안녕하세요. 문의 주신 단가는 내부 확인 후 오늘 중 정리해 회신드리겠습니다.\n${sign}`,
        options: [
          { id: "draft", label: "초안만 열기" },
          { id: "send", label: "지금 초안대로 보내기" },
          { id: "self", label: "내가 직접 / 나중에" },
        ],
        recommendedId: "draft",
        rationale: "가격·계약 류는 자동 발송하지 않고 초안으로 검토하는 것이 안전합니다.",
        risk: "high",
      },
    ] as OsDecision[],
    guardEvents: [
      { delayMs: 3200, text: "슬랙 멘션 1건 — 저위험 확인 요청, ARCA가 답장" },
      { delayMs: 7600, text: "뉴스레터 2건 — 소음, ZONE 종료 후 모아보기" },
      { delayMs: 12400, text: "미팅 리마인더 — 캘린더 확인 회신 발송" },
    ],
  };
}

/* ── Persistence ────────────────────────────────────────────── */

const STORE_KEY = "arcaos-v1";

interface SavedState {
  v: 1;
  profile: CompanyProfile;
  salt: number;
  name: string;
  owner?: string;
}

function loadSaved(): SavedState | null {
  try {
    const raw = localStorage.getItem(STORE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as SavedState;
    if (parsed?.v !== 1) return null;
    // Stale or hand-edited data must fall back to onboarding, never crash.
    const profile = sanitizeProfile(parsed.profile);
    if (!profile || typeof parsed.name !== "string" || !parsed.name.trim()) return null;
    return {
      v: 1,
      profile,
      salt: typeof parsed.salt === "number" ? parsed.salt : 0,
      name: parsed.name.trim().slice(0, 12),
      owner: typeof parsed.owner === "string" ? parsed.owner.trim().slice(0, 20) : undefined,
    };
  } catch {
    return null;
  }
}

/* ── Persona API ────────────────────────────────────────────── */

interface Persona {
  provider: "claude" | "demo";
  greeting: string;
  note: string;
  tip: string;
  warning?: string;
}

/* ── Small pieces ───────────────────────────────────────────── */

function fmtClock(totalSec: number): string {
  const m = Math.floor(totalSec / 60);
  const s = totalSec % 60;
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

function SpeechBubble({ text, loading }: { text: string; loading?: boolean }) {
  return (
    <div className="os-bubble" role="status">
      {loading ? (
        <span className="os-bubble-dots" aria-label="생각 중">
          <span /><span /><span />
        </span>
      ) : (
        text
      )}
    </div>
  );
}

/* ── Interview ──────────────────────────────────────────────── */

type Step = "company" | "industry" | "pace" | "tone" | "tools" | "focus";
const STEPS: Step[] = ["company", "industry", "pace", "tone", "tools", "focus"];

const QUESTIONS: Record<Step, (company: string) => string> = {
  company: () => "처음 뵙겠습니다. 어느 팀의 ZONE을 지키게 되나요?",
  industry: (c) => `${c}… 기억했습니다. 어떤 일을 하는 팀인가요?`,
  pace: () => "회의가 끝나면, 이 팀은 보통 어떻게 움직이나요?",
  tone: () => "제가 팀을 대신해 회신할 때, 어떤 말투가 좋을까요?",
  tools: () => "지금 팀의 대화는 어디에 쌓이고 있나요?",
  focus: () => "가장 지키고 싶은 몰입 시간은 언제인가요?",
};

/* ── Page ───────────────────────────────────────────────────── */

type Scene = "boot" | "interview" | "hatch" | "os";
type HatchPhase = "compress" | "crack" | "reveal";

export default function ArcaOsPage() {
  const [ready, setReady] = useState(false);
  const [scene, setScene] = useState<Scene>("boot");
  const [stepIdx, setStepIdx] = useState(0);

  // profile under construction
  const [company, setCompany] = useState("");
  const [owner, setOwner] = useState("");
  const [industry, setIndustry] = useState<IndustryKey | null>(null);
  const [pace, setPace] = useState<PaceKey | null>(null);
  const [tone, setTone] = useState<ToneKey | null>(null);
  const [tools, setTools] = useState<ToolKey[]>([]);
  const [focus, setFocus] = useState<FocusKey | null>(null);

  const [salt, setSalt] = useState(0);
  const [chosenName, setChosenName] = useState<string | null>(null);
  const [hatchPhase, setHatchPhase] = useState<HatchPhase>("compress");

  const [persona, setPersona] = useState<Persona | null>(null);
  const [personaLoading, setPersonaLoading] = useState(false);
  const personaReq = useRef(0);

  // OS state
  const [selected, setSelected] = useState<Record<string, string>>({});
  const [resolved, setResolved] = useState<Record<string, string>>({});
  const [zoneActive, setZoneActive] = useState(false);
  const [zoneSec, setZoneSec] = useState(0);
  const [zoneTotal, setZoneTotal] = useState(0);
  const [guardLog, setGuardLog] = useState<string[]>([]);
  const [lastReport, setLastReport] = useState<{ durationSec: number; items: string[] } | null>(null);
  const [guardHandled, setGuardHandled] = useState(0);
  const [moodOverride, setMoodOverride] = useState<CompanionMood | null>(null);
  const [speechOverride, setSpeechOverride] = useState<string | null>(null);
  const guardTimers = useRef<ReturnType<typeof setTimeout>[]>([]);
  const overrideTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const profile: CompanyProfile | null = useMemo(() => {
    if (!company || !industry || !pace || !tone || !focus) return null;
    return { company, industry, pace, tone, focus, tools };
  }, [company, industry, pace, tone, focus, tools]);

  const spec: CompanionSpec | null = useMemo(
    () => (profile ? generateCompanion(profile, salt) : null),
    [profile, salt],
  );

  const name = chosenName ?? spec?.name ?? "";
  const signName = owner.trim() || company || "우리 팀";
  const osData = useMemo(() => buildOsData(company || "우리 팀", signName), [company, signName]);

  /* restore a hatched companion */
  useEffect(() => {
    const saved = loadSaved();
    if (saved) {
      setCompany(saved.profile.company);
      setOwner(saved.owner ?? "");
      setIndustry(saved.profile.industry);
      setPace(saved.profile.pace);
      setTone(saved.profile.tone);
      setTools(saved.profile.tools);
      setFocus(saved.profile.focus);
      setSalt(saved.salt);
      setChosenName(saved.name);
      setScene("os");
    }
    setReady(true);
  }, []);

  /* hatch choreography */
  useEffect(() => {
    if (scene !== "hatch") return;
    setHatchPhase("compress");
    const t1 = setTimeout(() => setHatchPhase("crack"), 2400);
    const t2 = setTimeout(() => setHatchPhase("reveal"), 3700);
    return () => {
      clearTimeout(t1);
      clearTimeout(t2);
    };
  }, [scene, salt]);

  /* live persona at reveal (re-fires on reroll / name pick) */
  useEffect(() => {
    if (scene !== "hatch" || hatchPhase !== "reveal" || !profile) return;
    const req = ++personaReq.current;
    setPersonaLoading(true);
    fetch("/api/arcaos/companion", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ profile, salt, name: chosenName ?? undefined }),
    })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
      .then((data: { persona: Persona }) => {
        if (personaReq.current === req) setPersona(data.persona);
      })
      .catch(() => {
        if (personaReq.current === req) setPersona(null);
      })
      .finally(() => {
        if (personaReq.current === req) setPersonaLoading(false);
      });
  }, [scene, hatchPhase, profile, salt, chosenName]);

  /* zone timer */
  useEffect(() => {
    if (!zoneActive) return;
    const iv = setInterval(() => setZoneSec((s) => s + 1), 1000);
    return () => clearInterval(iv);
  }, [zoneActive]);

  const clearGuardTimers = useCallback(() => {
    guardTimers.current.forEach(clearTimeout);
    guardTimers.current = [];
  }, []);

  useEffect(() => () => clearGuardTimers(), [clearGuardTimers]);

  const flashMood = useCallback((mood: CompanionMood, speech: string | null, ms = 2600) => {
    if (overrideTimer.current) clearTimeout(overrideTimer.current);
    setMoodOverride(mood);
    setSpeechOverride(speech);
    overrideTimer.current = setTimeout(() => {
      setMoodOverride(null);
      setSpeechOverride(null);
    }, ms);
  }, []);

  const enterZone = useCallback(() => {
    setZoneActive(true);
    setZoneSec(0);
    setGuardLog([]);
    setLastReport(null);
    clearGuardTimers();
    osData.guardEvents.forEach((ev) => {
      guardTimers.current.push(
        setTimeout(() => {
          setGuardLog((log) => [...log, ev.text]);
          setGuardHandled((n) => n + 1);
        }, ev.delayMs),
      );
    });
  }, [clearGuardTimers, osData]);

  const leaveZone = useCallback(() => {
    clearGuardTimers();
    setZoneActive(false);
    setZoneTotal((t) => t + zoneSec);
    setLastReport({ durationSec: zoneSec, items: guardLog });
    if (spec) flashMood("reporting", spec.voiceLine, 4200);
  }, [clearGuardTimers, zoneSec, guardLog, spec, flashMood]);

  const resolveDecision = useCallback(
    (cardId: string, optionId: string) => {
      setResolved((r) => ({ ...r, [cardId]: optionId }));
      if (tone) flashMood("happy", SPEECH_RESOLVED[tone]);
    },
    [tone, flashMood],
  );

  const confirmCompanion = useCallback(() => {
    if (!profile || !spec) return;
    const finalName = chosenName ?? spec.name;
    try {
      localStorage.setItem(
        STORE_KEY,
        JSON.stringify({
          v: 1,
          profile,
          salt,
          name: finalName,
          owner: owner.trim() || undefined,
        } satisfies SavedState),
      );
    } catch {
      /* private mode — the session still works */
    }
    setChosenName(finalName);
    setScene("os");
  }, [profile, spec, chosenName, salt, owner]);

  const restart = useCallback(() => {
    try {
      localStorage.removeItem(STORE_KEY);
    } catch {
      /* ignore */
    }
    clearGuardTimers();
    setScene("boot");
    setStepIdx(0);
    setCompany("");
    setOwner("");
    setIndustry(null);
    setPace(null);
    setTone(null);
    setTools([]);
    setFocus(null);
    setSalt(0);
    setChosenName(null);
    setPersona(null);
    setSelected({});
    setResolved({});
    setZoneActive(false);
    setZoneSec(0);
    setZoneTotal(0);
    setGuardLog([]);
    setLastReport(null);
    setGuardHandled(0);
    setMoodOverride(null);
    setSpeechOverride(null);
  }, [clearGuardTimers]);

  /* ledger of what the core has understood so far */
  const ledger = useMemo(() => {
    const rows: { k: string; v: string }[] = [];
    if (company) rows.push({ k: "팀", v: company });
    if (owner.trim()) rows.push({ k: "서명", v: `– ${owner.trim()}'s ARCA` });
    if (industry) rows.push({ k: "업종", v: INDUSTRIES[industry].label });
    if (pace) rows.push({ k: "페이스", v: PACE_LABELS[pace].split(" — ")[0] });
    if (tone) rows.push({ k: "말투", v: TONE_LABELS[tone] });
    if (tools.length) rows.push({ k: "도구", v: tools.map((t) => TOOL_LABELS[t]).join(" · ") });
    if (focus) rows.push({ k: "몰입", v: FOCUS_LABELS[focus].split(" — ")[0] });
    return rows;
  }, [company, owner, industry, pace, tone, tools, focus]);

  const step = STEPS[stepIdx];
  const advanceTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const clearAdvanceTimer = useCallback(() => {
    if (advanceTimer.current) {
      clearTimeout(advanceTimer.current);
      advanceTimer.current = null;
    }
  }, []);
  useEffect(() => () => clearAdvanceTimer(), [clearAdvanceTimer]);

  const next = useCallback(() => {
    clearAdvanceTimer();
    setStepIdx((i) => Math.min(i + 1, STEPS.length - 1));
  }, [clearAdvanceTimer]);

  // Rapid double-clicks must not stack +1 updates (skipping a question would
  // dead-end the hatch scene), so the delayed advance is absolute + cancellable.
  const answerAndAdvance = useCallback(
    (apply: () => void) => {
      apply();
      if (stepIdx === STEPS.length - 1) {
        setScene("hatch");
        return;
      }
      clearAdvanceTimer();
      const from = stepIdx;
      advanceTimer.current = setTimeout(() => {
        advanceTimer.current = null;
        setStepIdx((i) => (i === from ? Math.min(i + 1, STEPS.length - 1) : i));
      }, 260);
    },
    [stepIdx, clearAdvanceTimer],
  );

  if (!ready) return <div className="os-root" />;

  const mood: CompanionMood = moodOverride ?? (zoneActive ? "guarding" : "idle");
  const pendingCount = osData.decisions.filter((d) => !resolved[d.id]).length;
  const handledCount = 2 + osData.handled.filter((h) => h.badge === "HANDLE").length + guardHandled +
    Object.entries(resolved).filter(([, opt]) => opt !== "self").length;
  const greetingText = persona?.greeting ?? (tone && name ? makeGreeting(tone, company, name) : "");

  return (
    <div className="os-root">
      <div className="os-bg" aria-hidden />

      <AnimatePresence mode="wait">
        {/* ───────────────────────── BOOT ───────────────────────── */}
        {scene === "boot" && (
          <motion.main key="boot" className="os-scene os-boot" variants={sceneV} initial="hidden" animate="show" exit="exit">
            <motion.div variants={staggerV(0.1, 0.14)} initial="hidden" animate="show" className="os-boot-inner">
              <motion.p variants={riseV} className="os-kicker">THE ZONE presents</motion.p>
              <motion.h1 variants={riseV} className="os-boot-title">ARCA OS</motion.h1>
              <motion.p variants={riseV} className="os-boot-sub">
                회사의 맥락을 이해하고, 몰입을 지키는 가디언을 부화시킵니다.
              </motion.p>
              <motion.div variants={riseV} className="os-boot-egg">
                <CoreEgg size={150} />
              </motion.div>
              <motion.button variants={riseV} className="os-cta" onClick={() => setScene("interview")}>
                온보딩 시작
              </motion.button>
              <motion.p variants={riseV} className="os-fineprint">
                arca os · companion hatchery · v0.1 — 키 없이도 전 과정이 동작합니다
              </motion.p>
            </motion.div>
          </motion.main>
        )}

        {/* ─────────────────────── INTERVIEW ─────────────────────── */}
        {scene === "interview" && (
          <motion.main key="interview" className="os-scene os-interview" variants={sceneV} initial="hidden" animate="show" exit="exit">
            <div className="os-iv-grid">
              <section className="os-iv-main">
                <div className="os-iv-egg">
                  <CoreEgg size={104} />
                </div>

                <div className="os-iv-progress" aria-label={`질문 ${stepIdx + 1} / ${STEPS.length}`}>
                  {STEPS.map((s, i) => (
                    <span key={s} className={`os-dot ${i <= stepIdx ? "os-dot--on" : ""}`} />
                  ))}
                </div>

                <AnimatePresence mode="wait">
                  <motion.div key={step} variants={sceneV} initial="hidden" animate="show" exit="exit" className="os-iv-block">
                    <div className="os-bubble os-bubble--core">{QUESTIONS[step](company)}</div>

                    {step === "company" && (
                      <form
                        className="os-iv-form"
                        onSubmit={(e) => {
                          e.preventDefault();
                          if (company.trim()) {
                            setCompany(company.trim());
                            setOwner(owner.trim());
                            next();
                          }
                        }}
                      >
                        <input
                          className="os-input"
                          value={company}
                          onChange={(e) => setCompany(e.target.value)}
                          placeholder="회사 또는 팀 이름 — 예: 더존바이오"
                          maxLength={40}
                          autoFocus
                        />
                        <input
                          className="os-input"
                          value={owner}
                          onChange={(e) => setOwner(e.target.value)}
                          placeholder="서명에 쓸 당신의 이름 (선택) — 예: 민"
                          maxLength={20}
                        />
                        <button type="submit" className="os-cta os-cta--sm" disabled={!company.trim()}>
                          다음 →
                        </button>
                      </form>
                    )}

                    {step === "industry" && (
                      <div className="os-choice-grid">
                        {(Object.keys(INDUSTRIES) as IndustryKey[]).map((key) => (
                          <button
                            key={key}
                            className={`os-chip ${industry === key ? "os-chip--on" : ""}`}
                            onClick={() => answerAndAdvance(() => setIndustry(key))}
                          >
                            <span className="os-chip-emoji" style={{ color: INDUSTRIES[key].accent }}>
                              {INDUSTRIES[key].emoji}
                            </span>
                            {INDUSTRIES[key].label}
                          </button>
                        ))}
                      </div>
                    )}

                    {step === "pace" && (
                      <div className="os-choice-col">
                        {(Object.keys(PACE_LABELS) as PaceKey[]).map((key) => (
                          <button
                            key={key}
                            className={`os-option ${pace === key ? "os-option--on" : ""}`}
                            onClick={() => answerAndAdvance(() => setPace(key))}
                          >
                            {PACE_LABELS[key]}
                          </button>
                        ))}
                      </div>
                    )}

                    {step === "tone" && (
                      <div className="os-choice-col">
                        {(Object.keys(TONE_LABELS) as ToneKey[]).map((key) => (
                          <button
                            key={key}
                            className={`os-option ${tone === key ? "os-option--on" : ""}`}
                            onClick={() => answerAndAdvance(() => setTone(key))}
                          >
                            <span>{TONE_LABELS[key]}</span>
                            <span className="os-option-sample">{TONE_SAMPLES[key]}</span>
                          </button>
                        ))}
                      </div>
                    )}

                    {step === "tools" && (
                      <>
                        <div className="os-choice-grid">
                          {(Object.keys(TOOL_LABELS) as ToolKey[]).map((key) => (
                            <button
                              key={key}
                              className={`os-chip ${tools.includes(key) ? "os-chip--on" : ""}`}
                              onClick={() =>
                                setTools((prev) =>
                                  prev.includes(key) ? prev.filter((t) => t !== key) : [...prev, key],
                                )
                              }
                            >
                              {TOOL_LABELS[key]}
                            </button>
                          ))}
                        </div>
                        <div className="os-iv-actions">
                          <button className="os-ghost" onClick={next}>
                            건너뛰기 — 연결은 나중에
                          </button>
                          <button className="os-cta os-cta--sm" onClick={next}>
                            {tools.length ? `다음 (${tools.length}) →` : "다음 →"}
                          </button>
                        </div>
                      </>
                    )}

                    {step === "focus" && (
                      <div className="os-choice-col">
                        {(Object.keys(FOCUS_LABELS) as FocusKey[]).map((key) => (
                          <button
                            key={key}
                            className={`os-option ${focus === key ? "os-option--on" : ""}`}
                            onClick={() => answerAndAdvance(() => setFocus(key))}
                          >
                            {FOCUS_LABELS[key]}
                          </button>
                        ))}
                      </div>
                    )}
                  </motion.div>
                </AnimatePresence>

                {stepIdx > 0 && (
                  <button
                    className="os-ghost os-back"
                    onClick={() => {
                      clearAdvanceTimer();
                      setStepIdx((i) => Math.max(0, i - 1));
                    }}
                  >
                    ← 이전 질문
                  </button>
                )}
              </section>

              <aside className="os-ledger" aria-label="회사 맥락">
                <div className="os-ledger-head">회사 맥락 · context</div>
                {ledger.length === 0 && <div className="os-ledger-empty">아직 비어 있습니다</div>}
                {ledger.map((row) => (
                  <div key={row.k} className="os-ledger-row">
                    <span>{row.k}</span>
                    <strong>{row.v}</strong>
                  </div>
                ))}
              </aside>
            </div>
          </motion.main>
        )}

        {/* ───────────────────────── HATCH ───────────────────────── */}
        {scene === "hatch" && spec && profile && (
          <motion.main key="hatch" className="os-scene os-hatch" variants={sceneV} initial="hidden" animate="show" exit="exit">
            {hatchPhase !== "reveal" && (
              <div className="os-hatch-stage">
                <CoreEgg size={170} cracking={hatchPhase === "crack"} />
                <div className="os-hatch-lines" aria-live="polite">
                  {ledger.map((row, i) => (
                    <div key={row.k} className="os-hatch-line" style={{ animationDelay: `${i * 0.28}s` }}>
                      {row.k}: {row.v}
                    </div>
                  ))}
                  <div className="os-hatch-line os-hatch-line--last" style={{ animationDelay: `${ledger.length * 0.28}s` }}>
                    {hatchPhase === "crack" ? "…부화 시작" : "…맥락 압축 중"}
                  </div>
                </div>
              </div>
            )}

            {hatchPhase === "reveal" && (
              <motion.div
                className="os-reveal"
                initial={{ opacity: 0, scale: 0.7, y: 26 }}
                animate={{ opacity: 1, scale: 1, y: 0 }}
                transition={{ type: "spring", stiffness: 210, damping: 18 }}
              >
                <div className="os-reveal-companion">
                  <GeneratedCompanion look={spec.look} mood="happy" size={210} />
                </div>

                <SpeechBubble text={greetingText} />
                {personaLoading && !persona ? (
                  <div className="os-provider">persona 깨어나는 중…</div>
                ) : persona ? (
                  <div className={`os-provider os-provider--${persona.provider}`}>
                    persona · {persona.provider === "claude" ? "live claude" : "demo"}
                  </div>
                ) : null}

                <div className="os-namepick">
                  {spec.nameCandidates.map((n) => (
                    <button
                      key={n}
                      className={`os-chip ${name === n ? "os-chip--on" : ""}`}
                      onClick={() => {
                        setChosenName(n);
                        setPersona(null);
                      }}
                    >
                      {n}
                    </button>
                  ))}
                  <button
                    className="os-ghost"
                    onClick={() => {
                      setChosenName(null);
                      setPersona(null);
                      setSalt((s) => s + 1);
                    }}
                  >
                    ↺ 다시 뽑기
                  </button>
                </div>

                <div className="os-card os-persona-card">
                  <div className="os-card-head">
                    <strong>{name}</strong>
                    <span className="os-archetype">{spec.archetype}</span>
                  </div>
                  <div className="os-traits">
                    {spec.traits.map((t) => (
                      <span key={t} className="os-trait">{t}</span>
                    ))}
                  </div>
                  <p className="os-voiceline">“{spec.voiceLine}”</p>
                  {persona?.note && <p className="os-persona-note">{persona.note}</p>}
                  <div className="os-delegations">
                    <div className="os-subhead">잘 맡기는 일</div>
                    <ul>
                      {spec.delegations.map((d) => (
                        <li key={d}>{d}</li>
                      ))}
                    </ul>
                  </div>
                  {persona?.tip && <p className="os-persona-tip">◆ {persona.tip}</p>}
                </div>

                <button className="os-cta" onClick={confirmCompanion}>
                  {name}와(과) 함께하기 →
                </button>
              </motion.div>
            )}
          </motion.main>
        )}

        {/* hatch dead-end guard: incomplete profile falls back to restart */}
        {scene === "hatch" && (!spec || !profile) && (
          <motion.main key="hatch-fallback" className="os-scene os-hatch" variants={sceneV} initial="hidden" animate="show" exit="exit">
            <div className="os-hatch-stage">
              <CoreEgg size={140} />
              <p className="os-boot-sub">답변이 일부 비어 있어 부화할 수 없습니다. 처음부터 다시 시작해 주세요.</p>
              <button className="os-cta" onClick={restart}>처음부터</button>
            </div>
          </motion.main>
        )}

        {/* ────────────────────────── OS ─────────────────────────── */}
        {scene === "os" && spec && (
          <motion.main key="os" className="os-scene os-home" variants={sceneV} initial="hidden" animate="show" exit="exit">
            <header className="os-bar">
              <div className="os-bar-left">
                <span className="os-bar-logo">ARCA OS</span>
                <span className="os-bar-sep">·</span>
                <span className="os-bar-company">{company}</span>
              </div>
              <div className="os-bar-right">
                <span className={`os-bar-status ${zoneActive ? "os-bar-status--guard" : ""}`}>
                  {zoneActive ? `가디언 사수 중 ${fmtClock(zoneSec)}` : "가디언 대기 중"}
                </span>
                <button className="os-ghost os-ghost--sm" onClick={restart}>처음부터</button>
              </div>
            </header>

            <motion.div variants={staggerV(0.05, 0.09)} initial="hidden" animate="show" className="os-home-body">
              {/* hero */}
              <motion.section variants={riseV} className="os-hero">
                <div className="os-hero-companion">
                  <GeneratedCompanion look={spec.look} mood={mood} size={168} />
                </div>
                <div className="os-hero-side">
                  <div className="os-hero-name">
                    <strong>{name}</strong>
                    <span>{spec.archetype}</span>
                  </div>
                  <SpeechBubble
                    text={speechOverride ?? (tone ? (zoneActive ? SPEECH_GUARD[tone] : SPEECH_IDLE[tone]) : "")}
                  />
                  <div className="os-statline">
                    자율 처리 {handledCount}건 · 판단 대기 {pendingCount}건 · ZONE {fmtClock(zoneTotal + (zoneActive ? zoneSec : 0))}
                  </div>
                  <div className="os-zone-actions">
                    {!zoneActive ? (
                      <button className="os-cta os-cta--zone" onClick={enterZone}>
                        Enter the ZONE
                      </button>
                    ) : (
                      <button className="os-cta os-cta--leave" onClick={leaveZone}>
                        Leave the ZONE · {fmtClock(zoneSec)}
                      </button>
                    )}
                  </div>
                  {zoneActive && (
                    <div className="os-guardlog" aria-live="polite">
                      {guardLog.length === 0 && <div className="os-guardlog-row os-guardlog-row--idle">조용합니다. 들어오는 것은 제가 먼저 봅니다.</div>}
                      {guardLog.map((line, i) => (
                        <div key={i} className="os-guardlog-row">✓ {line}</div>
                      ))}
                    </div>
                  )}
                  {!zoneActive && lastReport && (
                    <div className="os-report" aria-label="Expedition Report">
                      <div className="os-report-head">Expedition Report</div>
                      <div className="os-report-stat">
                        {fmtClock(lastReport.durationSec)} ZONE 사수 · {lastReport.items.length}건 흡수
                      </div>
                      {lastReport.items.length === 0 ? (
                        <div className="os-guardlog-row os-guardlog-row--idle">
                          자리를 비우신 동안 조용했습니다 — 깨끗한 복귀입니다.
                        </div>
                      ) : (
                        lastReport.items.map((line, i) => (
                          <div key={i} className="os-guardlog-row">✓ {line}</div>
                        ))
                      )}
                    </div>
                  )}
                </div>
              </motion.section>

              {/* sync strip */}
              <motion.section variants={riseV} className="os-section">
                <div className="os-section-head">
                  <h2>모든 기기, 하나의 기억</h2>
                  <span className="os-section-tag">SYNCED</span>
                </div>
                <div className="os-sync">
                  {osData.sync.map((s, i) => (
                    <div key={s.device} className="os-sync-node">
                      <div className="os-sync-card">
                        <div className="os-sync-device">
                          <span className="os-sync-icon">{s.icon}</span> {s.device}
                          <span className="os-sync-time">{s.time}</span>
                        </div>
                        <div className="os-sync-head">{s.head}</div>
                        <div className="os-sync-sub">{s.sub}</div>
                      </div>
                      {i < osData.sync.length - 1 && <div className="os-sync-link" aria-hidden><span /></div>}
                    </div>
                  ))}
                </div>
                <p className="os-section-note">어디서 잡아도 같은 곳에 쌓입니다 — Watch 캡처가 3분 뒤 Mac의 액션이 됩니다.</p>
              </motion.section>

              {/* memory */}
              <motion.section variants={riseV} className="os-section">
                <div className="os-section-head">
                  <h2>오늘의 기억</h2>
                  <span className="os-section-tag">MEMORY</span>
                </div>
                <div className="os-card os-memory">
                  <div className="os-memory-top">
                    <strong>{osData.memory.title}</strong>
                    <span className="os-memory-time">{osData.memory.time}</span>
                  </div>
                  <div className="os-speakers">
                    {osData.memory.speakers.map((sp) => (
                      <span key={sp.name} className="os-speaker">{sp.name} <em>{sp.talk}</em></span>
                    ))}
                  </div>
                  <p className="os-memory-summary">{osData.memory.summary}</p>
                  <div className="os-segments">
                    {osData.memory.segments.map((seg, i) => (
                      <div key={i} className="os-segment">
                        <span className={`os-segment-speaker os-segment-speaker--${i % 3}`}>{seg.speaker}</span>
                        <span className="os-segment-text">{seg.text}</span>
                      </div>
                    ))}
                  </div>
                  <div className="os-actions-list">
                    {osData.memory.actions.map((a) => (
                      <div key={a.title} className={`os-action ${a.done ? "os-action--done" : ""}`}>
                        <span className="os-action-mark">{a.done ? "✓" : "○"}</span>
                        <span className="os-action-title">{a.title}</span>
                        <span className={`os-action-owner ${a.owner === "ARCA" ? "os-action-owner--arca" : ""}`}>
                          {a.owner === "ARCA" ? `${name} 처리` : a.owner}
                        </span>
                      </div>
                    ))}
                  </div>
                  <div className="os-topics">
                    {osData.memory.topics.map((t) => (
                      <span key={t} className="os-topic">{t}</span>
                    ))}
                  </div>
                </div>
              </motion.section>

              {/* handled */}
              <motion.section variants={riseV} className="os-section">
                <div className="os-section-head">
                  <h2>{name}가 처리해둔 것</h2>
                  <span className="os-section-tag">HANDLED</span>
                </div>
                <div className="os-handled">
                  {osData.handled.map((h) => (
                    <div key={h.title} className="os-handled-row">
                      <span className="os-handled-icon">{h.icon}</span>
                      <div className="os-handled-main">
                        <div className="os-handled-title">{h.title}</div>
                        <div className="os-handled-meta">{h.from}</div>
                        <div className="os-handled-action">{h.action}</div>
                      </div>
                      <span className={`os-badge os-badge--${h.badge.toLowerCase()}`}>{h.badge}</span>
                    </div>
                  ))}
                </div>
              </motion.section>

              {/* decisions */}
              <motion.section variants={riseV} className="os-section">
                <div className="os-section-head">
                  <h2>당신의 판단이 필요한 것</h2>
                  <span className="os-section-tag">NEEDS YOU</span>
                </div>
                <div className="os-decisions">
                  {osData.decisions.map((d) => {
                    const done = resolved[d.id];
                    const sel = selected[d.id] ?? d.recommendedId;
                    return (
                      <div key={d.id} className={`os-card os-decision os-decision--${d.risk}`}>
                        <div className="os-decision-meta">
                          {d.source} · {d.from}
                        </div>
                        <div className="os-decision-q">{d.question}</div>
                        <blockquote className="os-draft">
                          <div className="os-draft-label">{name} pre-drafted</div>
                          {d.draft.split("\n").map((line, i) => (
                            <p key={i}>{line}</p>
                          ))}
                        </blockquote>
                        {done ? (
                          <div className="os-resolved">✓ Done — {d.options.find((o) => o.id === done)?.label}</div>
                        ) : (
                          <>
                            <div className="os-options" role="radiogroup" aria-label={d.question}>
                              {d.options.map((o) => (
                                <button
                                  key={o.id}
                                  role="radio"
                                  aria-checked={sel === o.id}
                                  className={`os-option os-option--slim ${sel === o.id ? "os-option--on" : ""}`}
                                  onClick={() => setSelected((s) => ({ ...s, [d.id]: o.id }))}
                                >
                                  <span>{o.label}</span>
                                  {o.id === d.recommendedId && <span className="os-recommend">{name} 추천</span>}
                                </button>
                              ))}
                            </div>
                            <button className="os-cta os-cta--sm" onClick={() => resolveDecision(d.id, sel)}>
                              Confirm →
                            </button>
                          </>
                        )}
                        <div className="os-rationale">◆ {d.rationale}</div>
                      </div>
                    );
                  })}
                </div>
              </motion.section>

              <motion.footer variants={riseV} className="os-footer">
                자율 회신은 ZONE 모드에서만 · 항상 「{`– ${signName}'s ARCA`}」 서명과 함께 · 가격·계약·HR 류는 자동 발송하지 않습니다
              </motion.footer>
            </motion.div>
          </motion.main>
        )}
      </AnimatePresence>
    </div>
  );
}
