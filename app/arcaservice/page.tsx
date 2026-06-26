"use client";

import { useState, useEffect, useRef } from "react";
import "./arcaservice.css";

/* ─── Data ─────────────────────────────────────────────── */

const SOURCES = [
  { id: "kakao", label: "KakaoTalk", icon: "💬", color: "#FFE01B", textColor: "#1a1714" },
  { id: "email", label: "Email", icon: "📧", color: "#4285F4", textColor: "#fff" },
  { id: "slack", label: "Slack", icon: "⚡", color: "#611f69", textColor: "#fff" },
  { id: "voice", label: "Voice Note", icon: "🎙", color: "#c2683a", textColor: "#fff" },
  { id: "meeting", label: "Meeting", icon: "📹", color: "#1f6f5c", textColor: "#fff" },
  { id: "doc", label: "Document", icon: "📄", color: "#7c746a", textColor: "#fff" },
];

const ROUTES = [
  { id: "ignore", label: "Ignore", color: "#a89f92", desc: "Noise, spam, FYI" },
  { id: "remember", label: "Remember", color: "#52796f", desc: "Context to log" },
  { id: "digest", label: "Digest", color: "#b0883c", desc: "Summarise later" },
  { id: "draft", label: "Draft Reply", color: "#4285F4", desc: "Needs a response" },
  { id: "ask", label: "Ask Me", color: "#c2683a", desc: "Ambiguous intent" },
  { id: "notify", label: "Notify Now", color: "#b8442e", desc: "Urgent / time-critical" },
  { id: "execute", label: "Auto Execute", color: "#1f6f5c", desc: "Known policy match" },
];

const MEMORY_STEPS = [
  { id: "capture", label: "Capture", icon: "⊙", desc: "Voice, text, meeting" },
  { id: "understand", label: "Understand", icon: "◎", desc: "Transcribe & parse" },
  { id: "classify", label: "Classify", icon: "◈", desc: "Intent & context" },
  { id: "decide", label: "Decide", icon: "◇", desc: "Route & risk check" },
  { id: "act", label: "Act", icon: "▷", desc: "Draft / execute" },
  { id: "confirm", label: "Confirm", icon: "✓", desc: "Human approval" },
  { id: "remember", label: "Remember", icon: "◉", desc: "Close the loop" },
  { id: "brief", label: "Pre-brief", icon: "→", desc: "Surface before next" },
];

const CRITERIA = [
  { label: "Risk", hi: "💥 High", lo: "✓ Low" },
  { label: "Reversibility", hi: "🔒 Locked", lo: "↩ Undoable" },
  { label: "Confidence", hi: "◎ High", lo: "? Ambiguous" },
  { label: "Urgency", hi: "⚡ Now", lo: "○ Later" },
  { label: "History", hi: "◉ Known", lo: "○ New" },
];

/* ─── Scroll-reveal hook ────────────────────────────────── */
function useInView(threshold = 0.15) {
  const ref = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const obs = new IntersectionObserver(
      ([entry]) => { if (entry.isIntersecting) setVisible(true); },
      { threshold }
    );
    obs.observe(el);
    return () => obs.disconnect();
  }, []);
  return { ref, visible };
}

/* ─── Section: Message Flow ─────────────────────────────── */
function MessageFlowSection() {
  const { ref, visible } = useInView();
  const [active, setActive] = useState<string | null>(null);
  const [flowing, setFlowing] = useState<string | null>(null);
  const [routed, setRouted] = useState<string | null>(null);

  function handleSource(id: string) {
    setActive(id);
    setFlowing(id);
    setRouted(null);
    const delay = setTimeout(() => {
      const pick = ROUTES[Math.floor(Math.random() * ROUTES.length)];
      setFlowing(null);
      setRouted(pick.id);
    }, 1400);
    return () => clearTimeout(delay);
  }

  return (
    <section className="svc-section" ref={ref} data-visible={visible}>
      <div className="svc-label">01 — Message Flow</div>
      <h2 className="svc-h2">세상의 모든 신호가<br />하나의 흐름으로</h2>
      <p className="svc-desc">
        KakaoTalk, 이메일, 슬랙, 음성 메모 — ARCA는 어디서 오든 받아서
        분석하고 최적의 행동으로 라우팅합니다. 소스를 클릭해보세요.
      </p>

      <div className="flow-canvas">
        {/* Sources */}
        <div className="flow-sources">
          {SOURCES.map((s) => (
            <button
              key={s.id}
              className={`flow-source ${active === s.id ? "flow-source--active" : ""}`}
              style={{ "--src-color": s.color, "--src-text": s.textColor } as React.CSSProperties}
              onClick={() => handleSource(s.id)}
            >
              <span className="flow-source-icon">{s.icon}</span>
              <span className="flow-source-label">{s.label}</span>
            </button>
          ))}
        </div>

        {/* Arrow + ARCA core */}
        <div className="flow-center">
          <div className={`flow-arrow ${flowing ? "flow-arrow--active" : ""}`}>
            <svg viewBox="0 0 120 24" fill="none" xmlns="http://www.w3.org/2000/svg">
              <line x1="0" y1="12" x2="100" y2="12" stroke="currentColor" strokeWidth="2" strokeDasharray="6 4"/>
              <polygon points="100,6 120,12 100,18" fill="currentColor"/>
            </svg>
          </div>

          <div className={`flow-core ${flowing ? "flow-core--pulse" : ""}`}>
            <div className="flow-core-ring" />
            <div className="flow-core-ring flow-core-ring--2" />
            <div className="flow-core-label">
              <span className="flow-core-name">ARCA</span>
              <span className="flow-core-sub">Memory Closed Loop OS</span>
            </div>
          </div>

          <div className={`flow-arrow flow-arrow--right ${routed ? "flow-arrow--active" : ""}`}>
            <svg viewBox="0 0 120 24" fill="none" xmlns="http://www.w3.org/2000/svg">
              <line x1="0" y1="12" x2="100" y2="12" stroke="currentColor" strokeWidth="2" strokeDasharray="6 4"/>
              <polygon points="100,6 120,12 100,18" fill="currentColor"/>
            </svg>
          </div>
        </div>

        {/* Output routes */}
        <div className="flow-outputs">
          {ROUTES.map((r) => (
            <div
              key={r.id}
              className={`flow-output ${routed === r.id ? "flow-output--active" : ""}`}
              style={{ "--route-color": r.color } as React.CSSProperties}
            >
              <span className="flow-output-dot" />
              <span className="flow-output-label">{r.label}</span>
              <span className="flow-output-desc">{r.desc}</span>
            </div>
          ))}
        </div>
      </div>

      <p className="flow-hint">← 소스를 클릭하면 ARCA가 실시간으로 라우팅합니다</p>
    </section>
  );
}

/* ─── Section: Decision Engine ──────────────────────────── */
function DecisionSection() {
  const { ref, visible } = useInView();
  const [scores, setScores] = useState([3, 2, 4, 3, 2]);
  const [result, setResult] = useState<typeof ROUTES[0]>(ROUTES[3]);

  function computeRoute(vals: number[]) {
    const [risk, rev, conf, urg, hist] = vals;
    if (risk >= 4 && rev >= 4) return ROUTES[5]; // notify
    if (risk >= 4) return ROUTES[4]; // ask me
    if (urg >= 4 && hist >= 3 && conf >= 3) return ROUTES[6]; // execute
    if (urg >= 4) return ROUTES[5]; // notify
    if (conf <= 2) return ROUTES[4]; // ask me
    if (risk >= 3) return ROUTES[3]; // draft
    if (hist >= 4) return ROUTES[1]; // remember
    return ROUTES[2]; // digest
  }

  function update(i: number, v: number) {
    const next = [...scores];
    next[i] = v;
    setScores(next);
    setResult(computeRoute(next));
  }

  return (
    <section className="svc-section svc-section--alt" ref={ref} data-visible={visible}>
      <div className="svc-label">02 — Decision Engine</div>
      <h2 className="svc-h2">7단계 판단 기준으로<br />올바른 행동을 선택</h2>
      <p className="svc-desc">
        Risk × Reversibility × Confidence × Urgency × History — 다섯 축의 점수가
        실시간으로 ARCA의 행동을 결정합니다. 슬라이더를 움직여보세요.
      </p>

      <div className="decision-canvas">
        <div className="decision-sliders">
          {CRITERIA.map((c, i) => (
            <div key={c.label} className="decision-row">
              <div className="decision-meta">
                <span className="decision-criterion">{c.label}</span>
                <span className="decision-ends">
                  <span>{c.lo}</span>
                  <span>{c.hi}</span>
                </span>
              </div>
              <input
                type="range"
                min={1}
                max={5}
                value={scores[i]}
                className="decision-slider"
                style={{ "--val": scores[i], "--route-color": result.color } as React.CSSProperties}
                onChange={(e) => update(i, Number(e.target.value))}
              />
              <div className="decision-pips">
                {[1, 2, 3, 4, 5].map((v) => (
                  <span key={v} className={`decision-pip ${scores[i] >= v ? "decision-pip--on" : ""}`}
                    style={{ "--route-color": result.color } as React.CSSProperties} />
                ))}
              </div>
            </div>
          ))}
        </div>

        <div className="decision-result" style={{ "--route-color": result.color } as React.CSSProperties}>
          <div className="decision-result-ring" />
          <div className="decision-result-body">
            <span className="decision-result-tag">ARCA will</span>
            <span className="decision-result-action">{result.label}</span>
            <span className="decision-result-why">{result.desc}</span>
          </div>
        </div>
      </div>

      {/* Route spectrum */}
      <div className="route-spectrum">
        {ROUTES.map((r) => (
          <div
            key={r.id}
            className={`route-chip ${result.id === r.id ? "route-chip--active" : ""}`}
            style={{ "--route-color": r.color } as React.CSSProperties}
          >
            {r.label}
          </div>
        ))}
      </div>
    </section>
  );
}

/* ─── Section: Memory Loop ──────────────────────────────── */
function MemoryLoopSection() {
  const { ref, visible } = useInView();
  const [step, setStep] = useState(0);

  useEffect(() => {
    if (!visible) return;
    const t = setInterval(() => setStep((s) => (s + 1) % MEMORY_STEPS.length), 1100);
    return () => clearInterval(t);
  }, [visible]);

  const cx = 200, cy = 200, r = 140;

  return (
    <section className="svc-section" ref={ref} data-visible={visible}>
      <div className="svc-label">03 — Memory Loop</div>
      <h2 className="svc-h2">한 번 경험한 것은<br />영원히 기억합니다</h2>
      <p className="svc-desc">
        캡처 → 이해 → 분류 → 결정 → 실행 → 확인 → 기억 → 사전 브리핑.
        8단계 클로즈드 루프가 끊임없이 돌아가며 당신의 두 번째 뇌를 만듭니다.
      </p>

      <div className="loop-canvas">
        <svg className="loop-svg" viewBox="0 0 400 400" xmlns="http://www.w3.org/2000/svg">
          {/* Track circle */}
          <circle cx={cx} cy={cy} r={r} fill="none" stroke="var(--line-2)" strokeWidth="1.5" strokeDasharray="4 3" />

          {/* Arc progress */}
          <circle
            cx={cx} cy={cy} r={r}
            fill="none"
            stroke="var(--accent)"
            strokeWidth="2.5"
            strokeDasharray={`${(step / MEMORY_STEPS.length) * 2 * Math.PI * r} 999`}
            strokeLinecap="round"
            transform={`rotate(-90 ${cx} ${cy})`}
            style={{ transition: "stroke-dasharray 0.6s var(--ease)" }}
          />

          {/* Step nodes */}
          {MEMORY_STEPS.map((s, i) => {
            const angle = (i / MEMORY_STEPS.length) * 2 * Math.PI - Math.PI / 2;
            const nx = cx + r * Math.cos(angle);
            const ny = cy + r * Math.sin(angle);
            const active = step === i;
            const past = step > i;
            return (
              <g key={s.id} onClick={() => setStep(i)} style={{ cursor: "pointer" }}>
                <circle
                  cx={nx} cy={ny} r={active ? 18 : 13}
                  fill={active ? "var(--accent)" : past ? "var(--accent-soft)" : "var(--paper-2)"}
                  stroke={active || past ? "var(--accent)" : "var(--line-2)"}
                  strokeWidth={active ? 2 : 1}
                  style={{ transition: "all 0.4s var(--ease)" }}
                />
                <text
                  x={nx} y={ny + 1}
                  textAnchor="middle"
                  dominantBaseline="middle"
                  fontSize={active ? 11 : 9}
                  fill={active ? "#fff" : past ? "var(--accent)" : "var(--ink-3)"}
                  style={{ transition: "all 0.4s var(--ease)", pointerEvents: "none", fontFamily: "var(--sans)" }}
                >
                  {i + 1}
                </text>
              </g>
            );
          })}

          {/* Center display */}
          <circle cx={cx} cy={cy} r={70} fill="var(--card)" stroke="var(--line)" strokeWidth="1" />
          <text x={cx} y={cy - 14} textAnchor="middle" fontSize="22" fill="var(--accent)">
            {MEMORY_STEPS[step].icon}
          </text>
          <text x={cx} y={cy + 8} textAnchor="middle" fontSize="13" fontWeight="600" fill="var(--ink)" fontFamily="var(--sans)">
            {MEMORY_STEPS[step].label}
          </text>
          <text x={cx} y={cy + 26} textAnchor="middle" fontSize="10" fill="var(--ink-3)" fontFamily="var(--sans)">
            {MEMORY_STEPS[step].desc}
          </text>
        </svg>

        <div className="loop-steps">
          {MEMORY_STEPS.map((s, i) => (
            <button
              key={s.id}
              className={`loop-step ${step === i ? "loop-step--active" : ""} ${step > i ? "loop-step--done" : ""}`}
              onClick={() => setStep(i)}
            >
              <span className="loop-step-num">{i + 1}</span>
              <span className="loop-step-body">
                <span className="loop-step-name">{s.label}</span>
                <span className="loop-step-desc">{s.desc}</span>
              </span>
            </button>
          ))}
        </div>
      </div>
    </section>
  );
}

/* ─── Section: Harness Marketplace ─────────────────────── */
const HARNESSES = [
  {
    name: "HR 갈등 리포트",
    category: "Labor Management",
    icon: "⚖️",
    trigger: "Meeting recording",
    output: "Risk report + KLES brief",
    autonomy: 2,
    color: "#b8442e",
  },
  {
    name: "주간 브리핑",
    category: "Executive",
    icon: "📋",
    trigger: "Every Monday 8AM",
    output: "Slack digest + calendar",
    autonomy: 4,
    color: "#1f6f5c",
  },
  {
    name: "계약 검토",
    category: "Legal",
    icon: "📝",
    trigger: "PDF attachment",
    output: "Risk flags + summary",
    autonomy: 3,
    color: "#4285F4",
  },
  {
    name: "팔로업 드래프트",
    category: "Sales",
    icon: "✉️",
    trigger: "Meeting ended",
    output: "Draft email + action items",
    autonomy: 3,
    color: "#c2683a",
  },
];

const AUTONOMY_LABELS = ["", "Suggest", "Draft", "Approve-to-send", "Auto-exec low risk", "Policy-based"];

function HarnessSection() {
  const { ref, visible } = useInView();
  const [selected, setSelected] = useState(0);
  const h = HARNESSES[selected];

  return (
    <section className="svc-section svc-section--alt" ref={ref} data-visible={visible}>
      <div className="svc-label">04 — Harness Marketplace</div>
      <h2 className="svc-h2">목적별로 설계된<br />실행 패키지</h2>
      <p className="svc-desc">
        Harness는 트리거 → 컨텍스트 → 프롬프트 체인 → 출력 형식 → 리스크 정책까지
        하나로 묶은 실행 패키지입니다. 누구나 만들고, 누구나 구독합니다.
      </p>

      <div className="harness-canvas">
        <div className="harness-list">
          {HARNESSES.map((h, i) => (
            <button
              key={h.name}
              className={`harness-card ${selected === i ? "harness-card--active" : ""}`}
              style={{ "--hcolor": h.color } as React.CSSProperties}
              onClick={() => setSelected(i)}
            >
              <span className="harness-icon">{h.icon}</span>
              <span className="harness-meta">
                <span className="harness-name">{h.name}</span>
                <span className="harness-cat">{h.category}</span>
              </span>
            </button>
          ))}
        </div>

        <div className="harness-detail" style={{ "--hcolor": h.color } as React.CSSProperties}>
          <div className="harness-detail-header">
            <span className="harness-detail-icon">{h.icon}</span>
            <div>
              <div className="harness-detail-name">{h.name}</div>
              <div className="harness-detail-cat">{h.category}</div>
            </div>
          </div>

          <div className="harness-flow">
            <div className="harness-flow-row">
              <span className="harness-flow-label">Trigger</span>
              <span className="harness-flow-val">{h.trigger}</span>
            </div>
            <div className="harness-flow-connector">↓</div>
            <div className="harness-flow-row">
              <span className="harness-flow-label">ARCA processes</span>
              <span className="harness-flow-val">Context · Memory · Risk check</span>
            </div>
            <div className="harness-flow-connector">↓</div>
            <div className="harness-flow-row">
              <span className="harness-flow-label">Output</span>
              <span className="harness-flow-val">{h.output}</span>
            </div>
          </div>

          <div className="harness-autonomy">
            <div className="harness-autonomy-label">Autonomy Level</div>
            <div className="harness-autonomy-track">
              {[1, 2, 3, 4, 5].map((v) => (
                <div
                  key={v}
                  className={`harness-autonomy-seg ${v <= h.autonomy ? "harness-autonomy-seg--on" : ""}`}
                  style={{ "--hcolor": h.color } as React.CSSProperties}
                />
              ))}
            </div>
            <div className="harness-autonomy-name">{AUTONOMY_LABELS[h.autonomy]}</div>
          </div>
        </div>
      </div>
    </section>
  );
}

/* ─── Main Page ─────────────────────────────────────────── */
export default function ArcaServicePage() {
  return (
    <main className="svc-root">
      {/* Hero */}
      <header className="svc-hero">
        <div className="svc-hero-tag">ARCA · Service</div>
        <h1 className="svc-hero-title">
          Memory Closed Loop OS
        </h1>
        <p className="svc-hero-sub">
          세상의 모든 신호를 받아, 기억하고, 판단하고, 행동합니다.<br />
          당신이 자리를 비워도 ARCA가 루프를 닫습니다.
        </p>
        <div className="svc-hero-pills">
          <span className="svc-pill">Autonomous Agent</span>
          <span className="svc-pill">Memory Layer</span>
          <span className="svc-pill">Harness Marketplace</span>
          <span className="svc-pill">Human-in-the-Loop</span>
        </div>
        <div className="svc-hero-scroll">↓</div>
      </header>

      {/* Visualizations */}
      <MessageFlowSection />
      <DecisionSection />
      <MemoryLoopSection />
      <HarnessSection />

      {/* CTA */}
      <section className="svc-cta">
        <div className="svc-cta-inner">
          <h2 className="svc-cta-title">지금 시작하세요</h2>
          <p className="svc-cta-sub">
            ARCA는 현재 초기 파트너를 모집 중입니다.<br />
            노무 컨설턴트, HR팀, 경영진을 위한 클로즈드 베타.
          </p>
          <div className="svc-cta-buttons">
            <a href="mailto:me@thezonebio.com" className="svc-btn svc-btn--primary">
              파트너 신청
            </a>
          </div>
        </div>
      </section>

      <footer className="svc-footer">
        <span>ARCA · The Zone Bio · 2026</span>
        <span>Memory Closed Loop OS</span>
      </footer>
    </main>
  );
}
