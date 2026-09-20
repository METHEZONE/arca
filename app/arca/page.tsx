"use client";

import { useEffect, useState } from "react";
import { motion, useReducedMotion } from "framer-motion";
import "./arca.css";

/* Served from thezonebio.com/arca via rewrite — auth/app routes must land on
   the arca origin so the session cookie works. */
const ARCA_ORIGIN = "https://arca-the-zone-bio.vercel.app";
function base(): string {
  if (typeof window === "undefined") return "";
  const h = window.location.hostname;
  return h === "localhost" || h.endsWith(".vercel.app") ? "" : ARCA_ORIGIN;
}

const EASE = [0.22, 1, 0.36, 1] as const;
const O = "#f75b2b";
const CREAM = "#fff3ea";
const MUT = "#6b625c";
const LINE = "#2a2320";

const fade = {
  hidden: { opacity: 0, y: 22 },
  show: { opacity: 1, y: 0, transition: { duration: 0.8, ease: EASE } },
};

/* ═══════════════════════════════════════════════════════════
   Hero graph — a Commitment Graph breathing behind the copy.
   Nodes light in sequence, paths grow forward, one node pulses.
   ═══════════════════════════════════════════════════════════ */
const HERO_NODES: Array<[number, number]> = [
  [520, 300], [640, 220], [660, 380], [790, 170], [800, 300], [780, 440],
  [930, 240], [940, 380], [1060, 160], [1080, 300], [1070, 450], [1210, 230],
  [1220, 360], [1350, 300],
];
const HERO_EDGES: Array<[number, number]> = [
  [0, 1], [0, 2], [1, 3], [1, 4], [2, 5], [3, 6], [4, 6], [4, 7], [5, 7], [6, 8], [6, 9],
  [7, 10], [8, 11], [9, 11], [9, 12], [10, 12], [11, 13], [12, 13],
];
const HERO_MAIN = new Set([0, 1, 4, 6, 9, 11, 13]);

function HeroGraph() {
  const reduce = useReducedMotion();
  return (
    <div className="a-hero-graph" aria-hidden="true">
      <svg viewBox="0 0 1440 600" preserveAspectRatio="xMidYMid slice">
        {HERO_EDGES.map(([a, b], i) => {
          const [x1, y1] = HERO_NODES[a];
          const [x2, y2] = HERO_NODES[b];
          const main = HERO_MAIN.has(a) && HERO_MAIN.has(b);
          return (
            <motion.line
              key={i}
              x1={x1}
              y1={y1}
              x2={x2}
              y2={y2}
              stroke={main ? O : LINE}
              strokeWidth={main ? 2.2 : 1.2}
              strokeOpacity={main ? 0.9 : 0.8}
              initial={reduce ? undefined : { pathLength: 0 }}
              animate={reduce ? undefined : { pathLength: 1 }}
              transition={{ duration: 0.9, delay: 0.5 + i * 0.16, ease: EASE }}
            />
          );
        })}
        {HERO_NODES.map(([x, y], i) => {
          const main = HERO_MAIN.has(i);
          return (
            <g key={i}>
              {main && (
                <motion.circle
                  cx={x}
                  cy={y}
                  r={14}
                  fill={O}
                  initial={{ opacity: 0 }}
                  animate={reduce ? { opacity: 0.18 } : { opacity: [0, 0.35, 0.1, 0.35] }}
                  transition={{ duration: 3, delay: 1 + i * 0.2, repeat: Infinity, ease: "easeInOut" }}
                />
              )}
              <motion.circle
                cx={x}
                cy={y}
                r={main ? 6 : 4}
                fill={main ? O : "#1a1512"}
                stroke={main ? O : "#3a302a"}
                strokeWidth={1.5}
                initial={{ scale: 0, opacity: 0 }}
                animate={{ scale: 1, opacity: 1 }}
                transition={{ duration: 0.5, delay: 0.4 + i * 0.16, ease: EASE }}
                style={{ transformOrigin: `${x}px ${y}px` }}
              />
            </g>
          );
        })}
        {/* the end node locks with evidence */}
        <motion.g
          initial={{ opacity: 0, scale: 0.6 }}
          animate={{ opacity: 1, scale: 1 }}
          transition={{ delay: 3.6, duration: 0.5, ease: EASE }}
          style={{ transformOrigin: "1350px 300px" }}
        >
          <circle cx={1350} cy={300} r={22} fill="none" stroke={O} strokeWidth={2} />
          <rect x={1342} y={296} width={16} height={12} rx={2} fill={O} />
          <path d="M1345 296 v-4 a5 5 0 0 1 10 0 v4" fill="none" stroke={O} strokeWidth={2.2} />
        </motion.g>
      </svg>
    </div>
  );
}

/* ═══════════════════════════════════════════════════════════
   Three transitions
   ═══════════════════════════════════════════════════════════ */
function ShiftVis1() {
  // scattered task chips → one living graph
  const chips = [
    [40, 40], [220, 20], [400, 60], [90, 160], [300, 150], [470, 190], [160, 260], [380, 270],
  ];
  const to = [
    [80, 150], [190, 90], [200, 210], [310, 60], [320, 150], [320, 240], [430, 110], [430, 200],
  ];
  return (
    <svg viewBox="0 0 520 300">
      {to.slice(0, -1).map(([x, y], i) => (
        <motion.line
          key={i}
          x1={x}
          y1={y}
          x2={to[i + 1][0]}
          y2={to[i + 1][1]}
          stroke={O}
          strokeWidth={1.8}
          initial={{ pathLength: 0, opacity: 0 }}
          whileInView={{ pathLength: 1, opacity: 1 }}
          viewport={{ once: true, amount: 0.5 }}
          transition={{ delay: 1.1 + i * 0.12, duration: 0.5, ease: EASE }}
        />
      ))}
      {chips.map(([x, y], i) => (
        <motion.g
          key={i}
          initial={{ x, y, opacity: 0.35 }}
          whileInView={{ x: to[i][0] - 46, y: to[i][1] - 14, opacity: 1 }}
          viewport={{ once: true, amount: 0.5 }}
          transition={{ delay: 0.2 + i * 0.08, duration: 0.9, ease: EASE }}
        >
          <rect width={92} height={28} rx={6} fill="#171210" stroke="#3a302a" />
          <rect x={10} y={11} width={54} height={6} rx={3} fill={i % 3 === 0 ? O : MUT} />
        </motion.g>
      ))}
    </svg>
  );
}

function ShiftVis2() {
  // generic output (gray) vs your definition of good: two rails feeding a taste model
  return (
    <svg viewBox="0 0 520 300">
      <text x={20} y={40} fill={MUT} fontSize={13} fontWeight={700} letterSpacing={1.5}>
        CONSENT · 맡길까?
      </text>
      <text x={20} y={190} fill={MUT} fontSize={13} fontWeight={700} letterSpacing={1.5}>
        QUALITY · 좋았나?
      </text>
      {[0, 1, 2, 3].map((i) => (
        <motion.rect
          key={`c${i}`}
          x={20 + i * 70}
          y={60}
          width={56}
          height={30}
          rx={6}
          fill="none"
          stroke={O}
          strokeWidth={1.6}
          initial={{ opacity: 0, x: 0 }}
          whileInView={{ opacity: [0, 1, 1, 0], x: [0, 0, 260, 320] }}
          viewport={{ once: true, amount: 0.5 }}
          transition={{ delay: 0.3 + i * 0.5, duration: 2.2, ease: "easeInOut", repeat: Infinity, repeatDelay: 1.5 }}
        />
      ))}
      {[0, 1, 2, 3].map((i) => (
        <motion.rect
          key={`q${i}`}
          x={20 + i * 70}
          y={210}
          width={56}
          height={30}
          rx={6}
          fill="none"
          stroke={CREAM}
          strokeWidth={1.4}
          strokeOpacity={0.8}
          initial={{ opacity: 0, x: 0 }}
          whileInView={{ opacity: [0, 1, 1, 0], x: [0, 0, 260, 320] }}
          viewport={{ once: true, amount: 0.5 }}
          transition={{ delay: 0.6 + i * 0.5, duration: 2.2, ease: "easeInOut", repeat: Infinity, repeatDelay: 1.5 }}
        />
      ))}
      <motion.g
        initial={{ opacity: 0, scale: 0.9 }}
        whileInView={{ opacity: 1, scale: 1 }}
        viewport={{ once: true }}
        transition={{ duration: 0.8, ease: EASE }}
        style={{ transformOrigin: "440px 150px" }}
      >
        <rect x={380} y={90} width={120} height={120} rx={14} fill="#120e0c" stroke={O} strokeWidth={2} />
        <text x={440} y={145} textAnchor="middle" fill={CREAM} fontSize={15} fontWeight={800}>
          Taste
        </text>
        <text x={440} y={166} textAnchor="middle" fill={CREAM} fontSize={15} fontWeight={800}>
          Model
        </text>
        <line x1={380} y1={150} x2={500} y2={150} stroke="#3a302a" />
      </motion.g>
    </svg>
  );
}

function ShiftVis3() {
  // prompt box (waiting) → proactive "ARCA it?" card
  return (
    <svg viewBox="0 0 520 300">
      <motion.g
        initial={{ opacity: 1 }}
        whileInView={{ opacity: 0.25 }}
        viewport={{ once: true, amount: 0.5 }}
        transition={{ delay: 1.2, duration: 0.8 }}
      >
        <rect x={20} y={40} width={300} height={48} rx={10} fill="#171210" stroke="#3a302a" />
        <text x={38} y={70} fill={MUT} fontSize={15}>
          Ask anything…
        </text>
        <motion.rect
          x={230}
          y={54}
          width={2}
          height={20}
          fill={MUT}
          animate={{ opacity: [1, 0, 1] }}
          transition={{ duration: 1, repeat: Infinity }}
        />
      </motion.g>
      <motion.g
        initial={{ opacity: 0, y: 30 }}
        whileInView={{ opacity: 1, y: 0 }}
        viewport={{ once: true, amount: 0.5 }}
        transition={{ delay: 1.3, duration: 0.8, ease: EASE }}
      >
        <rect x={120} y={130} width={380} height={140} rx={16} fill="#120e0c" stroke={O} strokeWidth={2} />
        <text x={144} y={162} fill={MUT} fontSize={12} fontWeight={800} letterSpacing={1.5}>
          회의 중 감지됨 · 14:32
        </text>
        <text x={144} y={192} fill={CREAM} fontSize={17} fontWeight={700}>
          “김 대표님께 금요일까지 견적 보내드릴게요”
        </text>
        <rect x={144} y={216} width={96} height={34} rx={9} fill={O} />
        <text x={192} y={238} textAnchor="middle" fill="#fff" fontSize={14} fontWeight={800}>
          ARCA it?
        </text>
        <text x={258} y={238} fill={MUT} fontSize={13}>
          나중에
        </text>
      </motion.g>
    </svg>
  );
}

/* ═══════════════════════════════════════════════════════════
   Core loop scene — auto-playing 7 beats
   ═══════════════════════════════════════════════════════════ */
const LOOP_STEPS = [
  { k: "01 감지", t: "회의·대화에서 약속을 감지" },
  { k: "02 제안", t: "“ARCA it?” 한 번 묻습니다" },
  { k: "03 범위", t: "시작→결과까지 드래그 = 위임 범위" },
  { k: "04 실행", t: "범위 안은 ARCA가 능동 실행" },
  { k: "05 경계", t: "범위 밖 판단은 먼저 질문" },
  { k: "06 증거", t: "외부 증거가 생기면 노드 lock" },
  { k: "07 학습", t: "동의와 품질을 따로 배움" },
];
const LOOP_NODES = [
  { x: 90, l: "약속 발생" },
  { x: 245, l: "후속 메일 초안" },
  { x: 400, l: "승인" },
  { x: 555, l: "발송" },
  { x: 710, l: "회신 · 가격 조정?" },
  { x: 865, l: "견적 수락" },
];
const LOOP_Y = 200;

function LoopScene() {
  const [step, setStep] = useState(0);
  const reduce = useReducedMotion();
  useEffect(() => {
    if (reduce) {
      setStep(6);
      return;
    }
    const id = setInterval(() => setStep((s) => (s + 1) % LOOP_STEPS.length), 2600);
    return () => clearInterval(id);
  }, [reduce]);

  const scoped = step >= 2; // scope drawn from node0 → node5
  const running = step >= 3;
  const boundary = step >= 4;
  const evidence = step >= 5;
  const learn = step >= 6;
  const executedCount = step === 3 ? 3 : step >= 4 ? 4 : 0; // nodes 1..3 run, node4 halts

  return (
    <div>
      <div className="loop-stage">
        <svg viewBox="0 0 1000 430">
          {/* transcript strip */}
          <g opacity={step === 0 || step === 1 ? 1 : 0.35}>
            <rect x={40} y={36} width={520} height={34} rx={8} fill="#171210" stroke={LINE} />
            <text x={56} y={58} fill={CREAM} fontSize={14}>
              …네, 김 대표님께 <tspan fill={O} fontWeight={800}>금요일까지 견적 보내드릴게요</tspan>. 그럼 다음 주에…
            </text>
            <motion.rect
              x={186}
              y={40}
              width={0}
              height={26}
              rx={5}
              fill={O}
              fillOpacity={0.18}
              animate={{ width: step >= 0 ? 214 : 0 }}
              transition={{ duration: 0.8, ease: EASE }}
            />
          </g>

          {/* ARCA it? card */}
          <motion.g
            initial={false}
            animate={{ opacity: step === 1 ? 1 : 0, y: step === 1 ? 0 : 10 }}
            transition={{ duration: 0.4 }}
          >
            <rect x={600} y={22} width={360} height={62} rx={12} fill="#120e0c" stroke={O} strokeWidth={1.6} />
            <text x={620} y={48} fill={MUT} fontSize={12} fontWeight={800} letterSpacing={1.4}>
              COMMITMENT DETECTED
            </text>
            <text x={620} y={70} fill={CREAM} fontSize={15} fontWeight={700}>
              견적 발송 → 수락까지 맡길까요?
            </text>
            <rect x={868} y={38} width={76} height={30} rx={8} fill={O} />
            <text x={906} y={58} textAnchor="middle" fill="#fff" fontSize={13} fontWeight={800}>
              ARCA it?
            </text>
          </motion.g>

          {/* scope region */}
          <motion.rect
            x={LOOP_NODES[0].x - 40}
            y={LOOP_Y - 70}
            height={140}
            rx={18}
            fill={O}
            fillOpacity={0.12}
            stroke={O}
            strokeOpacity={0.6}
            strokeDasharray="6 6"
            initial={false}
            animate={{ width: scoped ? LOOP_NODES[4].x + 40 - (LOOP_NODES[0].x - 40) : 0, opacity: scoped ? 1 : 0 }}
            transition={{ duration: 1.1, ease: EASE }}
          />
          <motion.text
            x={LOOP_NODES[0].x - 30}
            y={LOOP_Y - 82}
            fill={O}
            fontSize={12}
            fontWeight={800}
            letterSpacing={1.4}
            initial={false}
            animate={{ opacity: scoped ? 1 : 0 }}
          >
            이번 위임 범위
          </motion.text>

          {/* drag cursor */}
          {!reduce && (
            <motion.g
              initial={false}
              animate={
                step === 2
                  ? { x: [LOOP_NODES[0].x, LOOP_NODES[4].x], y: [LOOP_Y + 18, LOOP_Y + 18], opacity: [1, 1, 0] }
                  : { opacity: 0 }
              }
              transition={{ duration: 1.3, ease: EASE }}
            >
              <path d="M0 0 L0 18 L5 13 L9 21 L12 20 L8 12 L14 12 Z" fill={CREAM} stroke="#000" strokeWidth={0.8} />
            </motion.g>
          )}

          {/* edges */}
          {LOOP_NODES.slice(0, -1).map((n, i) => {
            const next = LOOP_NODES[i + 1];
            const lit = i === 0 ? true : running && i <= executedCount;
            return (
              <g key={i}>
                <line x1={n.x} y1={LOOP_Y} x2={next.x} y2={LOOP_Y} stroke={LINE} strokeWidth={3} />
                <motion.line
                  x1={n.x}
                  y1={LOOP_Y}
                  x2={next.x}
                  y2={LOOP_Y}
                  stroke={O}
                  strokeWidth={3}
                  initial={false}
                  animate={{ pathLength: lit ? 1 : 0, opacity: lit ? 1 : 0 }}
                  transition={{ duration: 0.6, delay: running ? i * 0.35 : 0, ease: EASE }}
                />
              </g>
            );
          })}

          {/* nodes */}
          {LOOP_NODES.map((n, i) => {
            const isStart = i === 0;
            const isBoundary = i === 4;
            const isGoal = i === 5;
            const done = isStart || (running && i <= executedCount && !isBoundary) || (isGoal && evidence) || (isBoundary && evidence);
            const pulsing = running && !evidence && (step === 3 ? i >= 1 && i <= 3 : false);
            const halted = isBoundary && boundary && !evidence;
            return (
              <g key={i}>
                {pulsing && (
                  <motion.circle
                    cx={n.x}
                    cy={LOOP_Y}
                    r={16}
                    fill={O}
                    animate={{ opacity: [0.35, 0, 0.35], scale: [1, 1.7, 1] }}
                    transition={{ duration: 1.4, repeat: Infinity, delay: i * 0.3 }}
                    style={{ transformOrigin: `${n.x}px ${LOOP_Y}px` }}
                  />
                )}
                <rect
                  x={n.x - 22}
                  y={LOOP_Y - 22}
                  width={44}
                  height={44}
                  rx={10}
                  fill={done ? O : "#171210"}
                  stroke={halted ? CREAM : done || (scoped && i <= 4) ? O : "#3a302a"}
                  strokeWidth={halted ? 2.4 : 1.6}
                  transform={`rotate(45 ${n.x} ${LOOP_Y})`}
                />
                {done && (
                  <g>
                    <rect x={n.x - 7} y={LOOP_Y - 2} width={14} height={10} rx={2} fill="#fff" />
                    <path d={`M${n.x - 4} ${LOOP_Y - 2} v-3 a4 4 0 0 1 8 0 v3`} fill="none" stroke="#fff" strokeWidth={2} />
                  </g>
                )}
                {halted && (
                  <text x={n.x} y={LOOP_Y + 6} textAnchor="middle" fill={CREAM} fontSize={20} fontWeight={900}>
                    ?
                  </text>
                )}
                <text x={n.x} y={LOOP_Y + 52} textAnchor="middle" fill={done ? CREAM : MUT} fontSize={13} fontWeight={700}>
                  {n.l}
                </text>
              </g>
            );
          })}

          {/* boundary question card */}
          <motion.g
            initial={false}
            animate={{ opacity: step === 4 ? 1 : 0, y: step === 4 ? 0 : 12 }}
            transition={{ duration: 0.4 }}
          >
            <rect x={560} y={276} width={400} height={84} rx={12} fill="#120e0c" stroke={CREAM} strokeOpacity={0.7} />
            <text x={580} y={302} fill={MUT} fontSize={12} fontWeight={800} letterSpacing={1.4}>
              범위 밖 판단 · ARCA가 먼저 묻습니다
            </text>
            <text x={580} y={326} fill={CREAM} fontSize={16} fontWeight={800}>
              가격을 5% 낮춰도 될까요?
            </text>
            <rect x={580} y={336} width={58} height={18} rx={5} fill={O} />
            <text x={609} y={349} textAnchor="middle" fill="#fff" fontSize={11} fontWeight={800}>
              승인
            </text>
            <text x={654} y={349} fill={MUT} fontSize={11} fontWeight={700}>
              수정
            </text>
            <text x={686} y={349} fill={MUT} fontSize={11} fontWeight={700}>
              거절
            </text>
          </motion.g>

          {/* evidence token */}
          {!reduce && (
            <motion.g
              initial={false}
              animate={step === 5 ? { x: [980, LOOP_NODES[5].x], y: [120, LOOP_Y - 44], opacity: [1, 1, 0] } : { opacity: 0 }}
              transition={{ duration: 1.1, ease: EASE }}
            >
              <rect x={-44} y={-14} width={88} height={28} rx={7} fill="#120e0c" stroke={O} />
              <text x={0} y={5} textAnchor="middle" fill={O} fontSize={11} fontWeight={800}>
                상대 회신 ✓
              </text>
            </motion.g>
          )}
          <motion.g initial={false} animate={{ opacity: evidence ? 1 : 0 }} transition={{ duration: 0.4 }}>
            <text x={LOOP_NODES[5].x} y={LOOP_Y - 44} textAnchor="middle" fill={O} fontSize={12} fontWeight={800} letterSpacing={1.2}>
              VERIFIED · 외부 증거로 잠김
            </text>
          </motion.g>

          {/* learning rails */}
          <motion.g initial={false} animate={{ opacity: learn ? 1 : 0 }} transition={{ duration: 0.5 }}>
            <text x={40} y={318} fill={O} fontSize={12} fontWeight={800} letterSpacing={1.4}>
              CONSENT · 승인 / 수정 / 거절
            </text>
            <text x={40} y={378} fill={CREAM} fontSize={12} fontWeight={800} letterSpacing={1.4} opacity={0.8}>
              QUALITY · 내 기준에 맞았나
            </text>
            <line x1={40} y1={334} x2={430} y2={334} stroke={O} strokeWidth={2} />
            <line x1={40} y1={394} x2={430} y2={394} stroke={CREAM} strokeOpacity={0.6} strokeWidth={2} />
            {[0, 1, 2].map((i) => (
              <motion.circle
                key={`cr${i}`}
                cy={334}
                r={5}
                fill={O}
                animate={learn ? { cx: [40, 430], opacity: [0, 1, 1, 0] } : {}}
                transition={{ duration: 1.8, delay: i * 0.6, repeat: Infinity, ease: "easeInOut" }}
              />
            ))}
            {[0, 1, 2].map((i) => (
              <motion.circle
                key={`qr${i}`}
                cy={394}
                r={5}
                fill={CREAM}
                animate={learn ? { cx: [40, 430], opacity: [0, 1, 1, 0] } : {}}
                transition={{ duration: 1.8, delay: 0.3 + i * 0.6, repeat: Infinity, ease: "easeInOut" }}
              />
            ))}
            <rect x={440} y={312} width={110} height={96} rx={12} fill="#120e0c" stroke={O} strokeWidth={1.6} />
            <text x={495} y={356} textAnchor="middle" fill={CREAM} fontSize={14} fontWeight={800}>
              Taste
            </text>
            <text x={495} y={376} textAnchor="middle" fill={CREAM} fontSize={14} fontWeight={800}>
              Model
            </text>
            <text x={495} y={396} textAnchor="middle" fill={MUT} fontSize={10} fontWeight={700}>
              두 신호를 섞지 않음
            </text>
          </motion.g>
        </svg>
        <div className="loop-caption">
          <span>{LOOP_STEPS[step].t}</span>
          <span>{LOOP_STEPS[step].k}</span>
        </div>
      </div>
      <div className="loop-steps" role="list">
        {LOOP_STEPS.map((s, i) => (
          <button
            key={s.k}
            type="button"
            className={`loop-step${i === step ? " on" : ""}`}
            onClick={() => setStep(i)}
            style={{ background: "none", textAlign: "left", cursor: "pointer", font: "inherit" }}
          >
            <b>{s.k}</b>
            {s.t}
          </button>
        ))}
      </div>
    </div>
  );
}

/* ═══════════════════════════════════════════════════════════
   A2A scene — two private graphs, only scoped packets cross
   ═══════════════════════════════════════════════════════════ */
function A2AScene() {
  const reduce = useReducedMotion();
  const cycle = 7;
  const g = (side: "l" | "r") => {
    const ox = side === "l" ? 60 : 640;
    const pts = [
      [ox + 40, 150], [ox + 130, 90], [ox + 130, 210], [ox + 220, 150], [ox + 300, 150],
    ];
    return (
      <g>
        <rect x={ox - 20} y={40} width={360} height={240} rx={18} fill="#0f0c0a" stroke={LINE} />
        <text x={ox} y={70} fill={MUT} fontSize={12} fontWeight={800} letterSpacing={1.4}>
          {side === "l" ? "MY ARCA · PRIVATE GRAPH" : "THEIR ARCA · PRIVATE GRAPH"}
        </text>
        {[[0, 1], [0, 2], [1, 3], [2, 3], [3, 4]].map(([a, b], i) => (
          <line key={i} x1={pts[a][0]} y1={pts[a][1]} x2={pts[b][0]} y2={pts[b][1]} stroke="#3a302a" strokeWidth={2} />
        ))}
        {pts.map(([x, y], i) => {
          const goal = i === 4;
          return (
            <g key={i}>
              {goal && (
                <motion.g
                  animate={reduce ? { opacity: 1 } : { opacity: [0, 0, 0, 1, 1, 1, 0] }}
                  transition={{ duration: cycle, repeat: Infinity, times: [0, 0.55, 0.7, 0.75, 0.9, 0.97, 1] }}
                >
                  <circle cx={x} cy={y} r={20} fill="none" stroke={O} strokeWidth={2} />
                  <rect x={x - 7} y={y - 2} width={14} height={10} rx={2} fill={O} />
                  <path d={`M${x - 4} ${y - 2} v-3 a4 4 0 0 1 8 0 v3`} fill="none" stroke={O} strokeWidth={2} />
                </motion.g>
              )}
              <circle cx={x} cy={y} r={goal ? 9 : 7} fill={i === 0 || goal ? O : "#171210"} stroke={O} strokeWidth={1.5} />
            </g>
          );
        })}
        <text x={ox} y={262} fill={MUT} fontSize={12}>
          원문 대화 · 개인 맥락 · 취향 = 건너가지 않음
        </text>
      </g>
    );
  };
  const packets: Array<{ label: string; dir: 1 | -1; t: number; y: number }> = [
    { label: "request", dir: 1, t: 0.05, y: 120 },
    { label: "authority", dir: -1, t: 0.3, y: 160 },
    { label: "evidence", dir: 1, t: 0.55, y: 200 },
  ];
  return (
    <div className="a2a-stage">
      <svg viewBox="0 0 1040 320">
        {g("l")}
        {g("r")}
        {/* lane */}
        <rect x={400} y={40} width={240} height={240} fill="url(#lane)" opacity={0.6} />
        <defs>
          <linearGradient id="lane" x1="0" x2="1">
            <stop offset="0" stopColor={O} stopOpacity={0} />
            <stop offset="0.5" stopColor={O} stopOpacity={0.12} />
            <stop offset="1" stopColor={O} stopOpacity={0} />
          </linearGradient>
        </defs>
        <text x={520} y={66} textAnchor="middle" fill={O} fontSize={12} fontWeight={800} letterSpacing={1.4}>
          SCOPED PACKET LANE
        </text>
        {/* gates */}
        {[400, 640].map((x, i) => (
          <motion.rect
            key={i}
            x={x - 3}
            y={90}
            width={6}
            height={140}
            rx={3}
            fill={O}
            animate={reduce ? { opacity: 0.9 } : { opacity: [0.25, 0.25, 0.95, 0.95, 0.25] }}
            transition={{ duration: cycle, repeat: Infinity, times: [0, 0.28, 0.32, 0.9, 1] }}
          />
        ))}
        <text x={400} y={250} textAnchor="middle" fill={MUT} fontSize={11} fontWeight={700}>
          내 승인 범위
        </text>
        <text x={640} y={250} textAnchor="middle" fill={MUT} fontSize={11} fontWeight={700}>
          상대 승인 범위
        </text>
        {packets.map((p) => (
          <motion.g
            key={p.label}
            animate={
              reduce
                ? { x: 520, opacity: 1 }
                : { x: p.dir === 1 ? [404, 636] : [636, 404], opacity: [0, 1, 1, 0] }
            }
            transition={{ duration: 1.6, delay: p.t * cycle, repeat: Infinity, repeatDelay: cycle - 1.6, ease: "easeInOut" }}
          >
            <rect x={-38} y={p.y - 12} width={76} height={24} rx={6} fill="#120e0c" stroke={O} />
            <text x={0} y={p.y + 4} textAnchor="middle" fill={O} fontSize={11} fontWeight={800}>
              {p.label}
            </text>
          </motion.g>
        ))}
        <text x={520} y={302} textAnchor="middle" fill={MUT} fontSize={12}>
          양쪽 게이트가 열려야 실행 · 양쪽 completion node가 증거로 잠겨야 종료
        </text>
      </svg>
    </div>
  );
}

/* ═══════════════════════════════════════════════════════════
   Page
   ═══════════════════════════════════════════════════════════ */
export default function ArcaLanding() {
  const [start, setStart] = useState("/arca/onboarding");
  useEffect(() => {
    setStart(`${base()}/arca/onboarding`);
  }, []);

  return (
    <div className="arca-root">
      <nav className="a-nav">
        <a className="a-logo" href="#top">
          arca
        </a>
        <div className="a-nav-links">
          <a href="#shift">비전</a>
          <a href="#loop">작동 방식</a>
          <a href="#a2a">ARCA ↔ ARCA</a>
          <a href="#status">현재 상태</a>
        </div>
        <a className="a-nav-cta" href={start}>
          Google로 시작
        </a>
      </nav>

      {/* HERO */}
      <header className="a-hero" id="top">
        <HeroGraph />
        <div className="a-hero-fade" />
        <div className="wrap">
          <motion.div className="a-hero-copy" initial="hidden" animate="show" transition={{ staggerChildren: 0.12 }}>
            <motion.p className="a-eyebrow" variants={fade}>
              Personal Life OS
            </motion.p>
            <motion.h1 className="a-h1" variants={fade}>
              약속을,
              <br />
              <span className="o">현실이 될 때까지.</span>
            </motion.h1>
            <motion.p className="a-lede" variants={fade}>
              ARCA는 회의와 일상 대화에서 당신의 약속을 감지하고, 당신이 그은 범위 안에서만 움직이고,
              바깥 세상의 증거가 생겨야 끝났다고 말합니다. 받아쓰는 AI는 많습니다. 끝내는 AI는 없습니다.
            </motion.p>
            <motion.div className="a-hero-ctas" variants={fade}>
              <a className="a-btn" href={start}>
                Google로 시작하기
              </a>
              <a className="a-btn-ghost" href="#loop">
                30초 안에 이해하기 ↓
              </a>
            </motion.div>
            <motion.div className="a-hero-meta" variants={fade}>
              <span>Mac 베타 · 녹음 → 전사 → 약속 감지</span>
              <span>승인 없이는 아무것도 나가지 않습니다</span>
              <span>원문은 당신의 기기에</span>
            </motion.div>
          </motion.div>
        </div>
      </header>

      {/* THREE SHIFTS */}
      <section className="a-section tight" id="shift">
        <div className="wrap">
          <motion.p className="a-eyebrow" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            세 가지 전환
          </motion.p>
          <motion.h2 className="a-h2" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            AI가 삶을 대신 고르는 미래가 아니라,
            <br />
            <span className="o">원하는 삶을 더 멀리 실행하는 미래.</span>
          </motion.h2>

          <motion.div className="a-shift" initial="hidden" whileInView="show" viewport={{ once: true, amount: 0.3 }} variants={fade} style={{ marginTop: 72 }}>
            <div>
              <span className="from">From fragmented tasks</span>
              <span className="to">
                to a <em>living model</em> of your life.
              </span>
              <p>
                흩어진 채팅창과 할 일 목록이 아니라, 사람·기한·조건·권한·증거가 연결된 하나의 Commitment
                Graph. 무엇을 했는지가 아니라 무엇이 아직 닫히지 않았는지를 관리합니다.
              </p>
            </div>
            <div className="a-shift-vis">
              <ShiftVis1 />
            </div>
          </motion.div>

          <motion.div className="a-shift" initial="hidden" whileInView="show" viewport={{ once: true, amount: 0.3 }} variants={fade}>
            <div>
              <span className="from">From generic intelligence</span>
              <span className="to">
                to <em>your definition</em> of good.
              </span>
              <p>
                맡겨도 되는가(consent)와 결과가 좋았는가(quality)를 따로 배웁니다. 더 많이 자동화해도
                당신의 경계는 흐려지지 않고, 권한은 습관만으로 넓어지지 않습니다.
              </p>
            </div>
            <div className="a-shift-vis">
              <ShiftVis2 />
            </div>
          </motion.div>

          <motion.div className="a-shift" initial="hidden" whileInView="show" viewport={{ once: true, amount: 0.3 }} variants={fade}>
            <div>
              <span className="from">From prompted assistance</span>
              <span className="to">
                to <em>proactive</em> orchestration.
              </span>
              <p>
                명령을 기다리지 않습니다. 약속이 생기는 순간 먼저 “ARCA it?” 하고 묻고, 허락한 만큼만
                움직이고, 경계에 닿으면 다시 묻습니다.
              </p>
            </div>
            <div className="a-shift-vis">
              <ShiftVis3 />
            </div>
          </motion.div>
        </div>
      </section>

      {/* CORE LOOP */}
      <section className="a-section" id="loop">
        <div className="wrap">
          <motion.p className="a-eyebrow" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            이렇게 작동합니다
          </motion.p>
          <motion.h2 className="a-h2" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            드래그한 만큼 맡기고,
            <br />
            <span className="o">증거가 생겨야 끝납니다.</span>
          </motion.h2>
          <motion.p className="a-sub" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            게임의 어치브먼트 맵처럼 시작점부터 현실의 결과까지가 한 장에 보입니다. 시작에서 원하는
            결과까지 드래그하면 그만큼이 이번 위임 범위입니다.
          </motion.p>
          <LoopScene />
          <div className="a-rows">
            <div className="a-row">
              <span className="n">BOUNDED AUTONOMY</span>
              <h4>범위 안은 실행, 밖은 질문.</h4>
              <p>
                견적 발송과 수락까지는 맡겼지만 가격을 낮추는 판단은 경계 밖입니다. ARCA는 멈추고 “5% 낮춰도
                될까요?”라고 묻습니다.
              </p>
            </div>
            <div className="a-row">
              <span className="n">VERIFIED CLOSURE</span>
              <h4>“보냈어요”가 아니라 “끝났어요”.</h4>
              <p>
                진행률은 자기 보고가 아닙니다. 상대 회신, 캘린더 수락, 입금, 배송처럼 바깥 세상의 증거가
                생길 때만 노드가 잠깁니다.
              </p>
            </div>
            <div className="a-row">
              <span className="n">TASTE LEARNING</span>
              <h4>맡길수록 알아서, 허락한 만큼만.</h4>
              <p>
                승인·수정·거절은 consent 레일로, 결과 만족은 quality 레일로 따로 흡수됩니다. 두 신호를 한
                점수로 섞지 않습니다.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* A2A */}
      <section className="a-section tight" id="a2a">
        <div className="wrap">
          <motion.p className="a-eyebrow" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            ARCA ↔ ARCA
          </motion.p>
          <motion.h2 className="a-h2" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            사람은 한 문장만.
            <br />
            <span className="o">확인은 ARCA끼리.</span>
          </motion.h2>
          <motion.p className="a-sub" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            두 ARCA는 전체 맥락을 합치지 않습니다. 필요한 request · authority · evidence packet만 교환해
            양쪽의 권한·일정·조건을 맞추고, 각자의 승인 범위 안에서 실행한 뒤, 양쪽 완료 노드가 증거로
            잠겨야 공동 약속이 끝납니다.
          </motion.p>
          <A2AScene />
          <div className="a2a-legend">
            <span>
              <i style={{ background: O }} />
              packet만 이동
            </span>
            <span>
              <i style={{ background: "#3a302a" }} />
              원문·개인 맥락은 각자의 그래프에
            </span>
            <span>
              <i style={{ background: CREAM }} />
              양쪽 게이트 = 각 사람의 승인 범위
            </span>
          </div>
          <motion.p className="a-kicker" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade} style={{ marginTop: 40, fontSize: "clamp(20px, 2.2vw, 30px)", color: CREAM, fontWeight: 800, letterSpacing: "-0.04em" }}>
            ARCA does not replace human relationships.
            <br />
            <span className="o">It removes the coordination tax around them.</span>
          </motion.p>
        </div>
      </section>

      {/* WORK SHELL */}
      <section className="a-section tight" id="work">
        <div className="wrap">
          <motion.p className="a-eyebrow" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            Company Brain AX
          </motion.p>
          <motion.h2 className="a-h2" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            별도 제품이 아닙니다.
            <br />
            <span className="o">ARCA의 Work Shell입니다.</span>
          </motion.h2>
          <div className="a-rows">
            <div className="a-row">
              <span className="n">SAME CORE</span>
              <h4>같은 감지·그래프·권한·증거 엔진</h4>
              <p>개인의 Personal Life OS가 회사 맥락을 입은 첫 번째 Shell. 회사 기억과 개인 기억은 분리합니다.</p>
            </div>
            <div className="a-row">
              <span className="n">INTER-COMPANY EXECUTION</span>
              <h4>회사와 회사 사이의 실행 레이어</h4>
              <p>회사 간에도 request · authority · evidence packet만 오갑니다. 사람은 승인 한 번, 후속은 ARCA끼리.</p>
            </div>
            <div className="a-row">
              <span className="n">FIRST DEPLOYMENT</span>
              <h4>기업도 같은 문제에 돈을 냅니다</h4>
              <p>첫 ARCA AX 도입은 합의 후 계약 문서화 진행 중입니다. 서명·입금 전에는 매출로 말하지 않습니다.</p>
            </div>
          </div>
        </div>
      </section>

      {/* STATUS */}
      <section className="a-section tight" id="status">
        <div className="wrap">
          <motion.p className="a-eyebrow" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            지금 어디까지 되나
          </motion.p>
          <motion.h2 className="a-h2" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            되는 것만 <span className="o">된다고</span> 말합니다.
          </motion.h2>
          <div className="a-status">
            <div>
              <span className="pill live">Live</span>
              <h5>오늘 쓸 수 있는 것</h5>
              <ul>
                <li>Google 로그인 · 웹 온보딩</li>
                <li>Mac 베타: 녹음 → 전사 → 요약 · 액션 추출</li>
                <li>웹: 대화 붙여넣기 → 약속 감지 → “ARCA it?”</li>
                <li>Commitment Graph · 드래그 위임 범위 · 초안 생성</li>
              </ul>
            </div>
            <div>
              <span className="pill proto">Prototype</span>
              <h5>동작하지만 시뮬레이션인 것</h5>
              <ul>
                <li>외부 증거 잠금 (지금은 직접 붙여넣기)</li>
                <li>consent / quality 분리 학습 (기록만, 반영 전)</li>
                <li>ARCA ↔ ARCA scoped packet 교환</li>
              </ul>
            </div>
            <div>
              <span className="pill next">Coming next</span>
              <h5>아직 안 되는 것</h5>
              <ul>
                <li>Gmail · Calendar 연결 발송 · 자동 증거 수집</li>
                <li>Slack · 결제 · 배송 evidence adapter</li>
                <li>ARCA Core 하드웨어 (폰이 못 듣는 순간)</li>
              </ul>
            </div>
          </div>
        </div>
      </section>

      {/* FINAL */}
      <section className="a-final">
        <div className="wrap">
          <motion.h2 className="a-h1" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            arca <span className="o">해놔.</span>
          </motion.h2>
          <motion.p className="a-lede" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade} style={{ margin: "28px auto 0" }}>
            쫓아다니는 시간을 돌려드립니다. 만드는 데 쓰세요.
          </motion.p>
          <motion.div className="a-hero-ctas" initial="hidden" whileInView="show" viewport={{ once: true }} variants={fade}>
            <a className="a-btn" href={start}>
              Google로 시작하기
            </a>
            <a className="a-btn-ghost" href={`${base()}/api/arca/download?t=mac-zip&src=landing-final`} target="_blank" rel="noreferrer">
              Mac 베타 받기
            </a>
          </motion.div>
        </div>
        <div className="wrap a-footer">
          <span>THE ZONE · ARCA · me@thezonebio.com</span>
          <span>
            <a href="/arca/privacy">Privacy</a> · <a href="/arca/terms">Terms</a> · <a href="/arcaconnect">Tapped Min&apos;s ring? →</a>
          </span>
        </div>
      </section>
    </div>
  );
}
