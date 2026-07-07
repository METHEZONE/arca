"use client";

import { useRef, useState } from "react";
import { motion, useAnimationFrame } from "framer-motion";
import Deck from "../arca-pitch0/Deck";
import { AnimatedNumber } from "../arca-pitch0/components";
import { blurUp, EASE_OUT, fadeUp, scaleIn, stagger } from "../arca-pitch0/motion";
import type { SlideDef, SlideProps } from "../arca-pitch0/slides/types";
import "../arca-pitch0/pitch.css";
import "./arcahyundai.css";

/* ────────────────────────────────────────────────────────────
   Asset base — absolute for cross-domain (thezone.bio proxies
   only the page HTML, not /photos / /brand / /media assets)
   ──────────────────────────────────────────────────────────── */
const A = "https://arca-nine.vercel.app";

/* ────────────────────────────────────────────────────────────
   Shared helpers
   ──────────────────────────────────────────────────────────── */

function Tag({ children }: { children: React.ReactNode }) {
  return <span className="hy-tag">{children}</span>;
}

function Header({
  eyebrow,
  title,
  sub,
}: {
  eyebrow: string;
  title: React.ReactNode;
  sub?: React.ReactNode;
}) {
  return (
    <motion.div variants={stagger(0.1, 0.12)} initial="hidden" animate="show" className="hy-head">
      <motion.p variants={fadeUp} className="deck-eyebrow">{eyebrow}</motion.p>
      <motion.h2 variants={blurUp} className="deck-h2">{title}</motion.h2>
      {sub && <motion.p variants={fadeUp} className="hy-sub">{sub}</motion.p>}
    </motion.div>
  );
}

function Source({ children }: { children: React.ReactNode }) {
  return <p className="hy-source">{children}</p>;
}

function Honesty({ children, tone = "warn" }: { children: React.ReactNode; tone?: "warn" | "muted" }) {
  return <div className={`hy-candor hy-candor--${tone}`}>{children}</div>;
}

/* ────────────────────────────────────────────────────────────
   BrandLogo — clearbit logo with graceful fallback chip
   ──────────────────────────────────────────────────────────── */
const LOGO_SRCS = (domain: string) => [
  `https://logo.clearbit.com/${domain}`,
  `https://t2.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https://${domain}&size=128`,
];

function BrandLogo({
  name,
  domain,
  fallbackBg,
  fallbackColor,
  size,
  "data-logo-slot": slot,
}: {
  name: string;
  domain?: string;
  fallbackBg?: string;
  fallbackColor?: string;
  size?: number;
  "data-logo-slot"?: string;
}) {
  const [srcIdx, setSrcIdx] = useState(0);
  const srcs = domain ? LOGO_SRCS(domain) : [];

  if (!domain || srcIdx >= srcs.length) {
    return (
      <span
        className="hy-brand-chip"
        style={{
          background: fallbackBg,
          color: fallbackColor,
          ...(size ? { width: size, height: size, fontSize: size * 0.42, borderRadius: size * 0.22 } : {}),
        }}
        data-logo-slot={slot}
      >
        {name}
      </span>
    );
  }

  return (
    <img
      className="hy-brand-logo"
      src={srcs[srcIdx]}
      alt={name}
      style={size ? { width: size, height: size, borderRadius: size * 0.22 } : undefined}
      onError={() => setSrcIdx((i) => i + 1)}
      loading="lazy"
    />
  );
}

/* ────────────────────────────────────────────────────────────
   ArcaFace — the qbit companion, idle animation
   ──────────────────────────────────────────────────────────── */
function ArcaFace({ size = 160 }: { size?: number }) {
  return (
    <motion.div
      className="hy-face-wrap"
      style={{ width: size, height: size * (210 / 220) }}
      animate={{ y: [0, -7, 0] }}
      transition={{
        duration: 3.8,
        ease: "easeInOut",
        repeat: Infinity,
        repeatType: "loop",
      }}
    >
      {/* clean companion: rounded head + two glowing eyes; the SVG handles its own blink via SMIL */}
      <img
        src={`${A}/brand/arca-companion.svg`}
        alt="ARCA companion character"
        className="hy-face-img"
      />
    </motion.div>
  );
}

/* ────────────────────────────────────────────────────────────
   ContextLoopDiagram — animated circular loop for S10
   ──────────────────────────────────────────────────────────── */
const LOOP_NODES = [
  { id: "capture", label: "캡처", sub: "회의·메시지", angle: -90 },
  { id: "decide", label: "판단·실행", sub: "H / D / E", angle: 0 },
  { id: "complete", label: "완수 데이터", sub: "닫힌 루프", angle: 90 },
  { id: "accumulate", label: "맥락 축적", sub: "개인·팀 코어", angle: 180 },
];

function ContextLoopDiagram({ active }: { active: boolean }) {
  const progressRef = useRef(0);
  const [prog, setProgress] = useState(0);

  useAnimationFrame((_, delta) => {
    if (!active) return;
    progressRef.current = (progressRef.current + delta * 0.00025) % 1;
    setProgress(progressRef.current);
  });

  const R = 120; // orbit radius
  const cx = 200;
  const cy = 200;

  // travelling dot angle from progress
  const travelAngle = prog * 360 - 90;
  const travelRad = (travelAngle * Math.PI) / 180;
  const dotX = cx + R * Math.cos(travelRad);
  const dotY = cy + R * Math.sin(travelRad);

  // centre glow intensity pulses as loop completes (prog wraps at 1)
  const glowPulse = 0.4 + 0.6 * Math.abs(Math.sin(prog * Math.PI * 2));

  return (
    <div className="hy-loop-wrap">
      <svg viewBox="0 0 400 400" className="hy-loop-svg" aria-hidden="true">
        {/* orbit ring */}
        <circle cx={cx} cy={cy} r={R} fill="none" stroke="rgba(255,237,215,0.1)" strokeWidth="1" />
        {/* arc fill — grows with progress */}
        <circle
          cx={cx} cy={cy} r={R}
          fill="none"
          stroke="rgba(255,122,26,0.35)"
          strokeWidth="2"
          strokeDasharray={`${prog * 2 * Math.PI * R} ${2 * Math.PI * R}`}
          strokeDashoffset={0}
          transform={`rotate(-90 ${cx} ${cy})`}
        />
        {/* travelling dot */}
        <motion.circle cx={dotX} cy={dotY} r={5} fill="var(--accent)" opacity={0.9} />
        {/* centre core — grows brighter as loop accumulates */}
        <circle
          cx={cx} cy={cy}
          r={32 + glowPulse * 12}
          fill={`rgba(220,80,0,${0.1 + glowPulse * 0.15})`}
        />
        <circle
          cx={cx} cy={cy} r={32}
          fill="#120900"
          stroke="rgba(255,122,26,0.55)"
          strokeWidth="1.5"
        />
        {/* nodes */}
        {LOOP_NODES.map((node) => {
          const rad = (node.angle * Math.PI) / 180;
          const nx = cx + R * Math.cos(rad);
          const ny = cy + R * Math.sin(rad);
          return (
            <g key={node.id}>
              <circle cx={nx} cy={ny} r={22} fill="#1a0d07" stroke="rgba(255,122,26,0.45)" strokeWidth="1.5" />
              <text x={nx} y={ny - 4} textAnchor="middle" fill="#ffedd7" fontSize="10" fontFamily="var(--sans)" fontWeight="600">{node.label}</text>
              <text x={nx} y={ny + 10} textAnchor="middle" fill="rgba(255,237,215,0.5)" fontSize="8" fontFamily="var(--mono)">{node.sub}</text>
            </g>
          );
        })}
        {/* centre label */}
        <text x={cx} y={cy - 6} textAnchor="middle" fill="rgba(255,237,215,0.8)" fontSize="11" fontFamily="var(--sans)" fontWeight="600">컨텍스트</text>
        <text x={cx} y={cy + 8} textAnchor="middle" fill="rgba(255,122,26,0.9)" fontSize="10" fontFamily="var(--mono)">코어</text>
        <text x={cx} y={cy + 22} textAnchor="middle" fill="rgba(255,237,215,0.35)" fontSize="8" fontFamily="var(--mono)">누적 중</text>
      </svg>
      <div className="hy-loop-copy">
        <p className="hy-loop-line">루프를 돌수록,<br /><b>당신의 일을 더 잘 압니다.</b></p>
        <ul className="hy-loop-nodes">
          {LOOP_NODES.map((n) => (
            <li key={n.id}><b>{n.label}</b><span>{n.sub}</span></li>
          ))}
        </ul>
      </div>
    </div>
  );
}

/* ────────────────────────────────────────────────────────────
   S1 — TITLE  (ARCA face + pixel wordmark)
   ──────────────────────────────────────────────────────────── */
function Slide01Title(_: SlideProps) {
  return (
    <section className="slide slide--center slide--glow hy-title-slide">
      <motion.div
        className="hy-title-ring"
        initial={{ opacity: 0, scale: 0.75 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ duration: 1.2, ease: EASE_OUT }}
      />
      <motion.div className="hy-title-stack" variants={stagger(0.12, 0.18)} initial="hidden" animate="show">
        <motion.p variants={fadeUp} className="deck-eyebrow">ARCA · THE ZONE BIO</motion.p>

        {/* face sits above or beside the wordmark */}
        <motion.div variants={scaleIn} className="hy-face-lockup">
          <ArcaFace size={200} />
        </motion.div>

        <motion.h1 variants={blurUp} className="hy-arca">ARCA</motion.h1>

        <motion.p variants={fadeUp} className="hy-one-line">
          회의·업무 메시지 뒤에 남는 일을 <span>실제로 닫아주는</span> AI 업무 위임 레이어.
        </motion.p>
        <motion.div variants={fadeUp} className="hy-role-row">
          <Tag>발표 · 박민성</Tag>
          <Tag>2026.06.26 · ZER01NE Sprint</Tag>
          <Tag>thezone.bio/arcahyundai</Tag>
        </motion.div>
      </motion.div>
      <motion.div
        className="hy-title-mark"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ delay: 1.1, duration: 0.9 }}
      >
        "arca 해놔."
      </motion.div>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S2 — OPEN: 좋은 사람이 병목이 됩니다
   ──────────────────────────────────────────────────────────── */
function Slide02Problem(_: SlideProps) {
  return (
    <section className="slide slide--glow hy-problem">
      <Header
        eyebrow="01 PROBLEM"
        title={<>좋은 사람이<br /><span className="deck-accent">조직의 답변 대기열</span>이 됩니다.</>}
        sub="하나하나는 어렵지 않습니다. 그런데 안 하면 일이 멈추고, 하면 몰입이 깨집니다."
      />
      <motion.div className="hy-message-flow" variants={stagger(0.16, 0.36)} initial="hidden" animate="show">
        {["사업계획서 다시 보내주세요", "견적서 주시면 오늘 결제하겠습니다", "지난 회의 다음 단계가 뭐였죠?"].map((msg, i) => (
          <motion.div key={msg} variants={fadeUp} className={`hy-bubble hy-bubble-${i + 1}`}>{msg}</motion.div>
        ))}
        <motion.div variants={scaleIn} className="hy-human-node">
          <b>1명</b>
          <span>모든 후속조치가<br />여기로 모입니다</span>
        </motion.div>
      </motion.div>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S3 — DATA 57 / 43 / 68
   ──────────────────────────────────────────────────────────── */
const COMM_APPS = [
  { name: "Zoom", domain: "zoom.us" },
  { name: "Gmail", domain: "gmail.com" },
  { name: "Slack", domain: "slack.com" },
];
const CREATE_APPS = [
  { name: "X", bg: "#1D6F42", color: "#fff" },
  { name: "P", bg: "#C43E1C", color: "#fff" },
  { name: "W", bg: "#185ABD", color: "#fff" },
];

function Slide03Data({ active }: SlideProps) {
  return (
    <section className="slide slide--glow hy-data">
      <Header
        eyebrow="02 DATA"
        title={<>업무의 절반 이상은<br /><span className="deck-accent">일 주변의 교통정리</span>입니다.</>}
        sub="Microsoft Work Trend Index 기준. ARCA는 57% 전체가 아니라, 반복적이고 낮은 위험의 후속조치를 겨냥합니다."
      />
      <div className="hy-split">
        <motion.div
          className="hy-split-comm"
          initial={{ width: 0 }}
          animate={{ width: active ? "57%" : 0 }}
          transition={{ duration: 1.15, ease: EASE_OUT, delay: 0.35 }}
        >
          <b><AnimatedNumber value={57} suffix="%" play={active} /></b>
          <div className="hy-app-icons">
            {COMM_APPS.map((app) => (
              <BrandLogo key={app.name} name={app.name} domain={app.domain} fallbackBg="rgba(0,0,0,0.3)" fallbackColor="#fff" />
            ))}
          </div>
          <span>커뮤니케이션 (회의·이메일·채팅)</span>
        </motion.div>
        <motion.div
          className="hy-split-create"
          initial={{ width: 0 }}
          animate={{ width: active ? "43%" : 0 }}
          transition={{ duration: 1.15, ease: EASE_OUT, delay: 0.48 }}
        >
          <b><AnimatedNumber value={43} suffix="%" play={active} /></b>
          <div className="hy-app-icons">
            {CREATE_APPS.map((app) => (
              <span key={app.name} className="hy-app-chip" style={{ background: app.bg, color: app.color }}>{app.name}</span>
            ))}
          </div>
          <span>창작 (문서·발표)</span>
        </motion.div>
      </div>
      <motion.div
        className="hy-gap-callout"
        initial={{ opacity: 0, y: 14 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 1.05, ease: EASE_OUT }}
      >
        <span className="hy-gap-kicker">Context-to-Completion Gap</span>
        <p>노트가 부족한 게 아닙니다. 모든 업무는 <em>당신의 머릿속을 통과해야만</em> 끝납니다.{" "}
          우리는 그 간극을 <b>Context-to-Completion Gap</b>이라 부릅니다 —{" "}
          그리고 지금 그 자리를 채우고 있는 건 <b>당신</b>입니다.</p>
      </motion.div>
      <motion.div className="hy-data-cards" variants={stagger(0.14, 0.9)} initial="hidden" animate="show">
        <motion.div variants={fadeUp}>
          <b><AnimatedNumber value={68} suffix="%" play={active} /></b>
          <span>방해받지 않는 집중시간이 부족하다</span>
        </motion.div>
        <motion.div variants={fadeUp}>
          <b><AnimatedNumber value={40} prefix="n=" play={active} /></b>
          <span>한국 동료 창업자 직접 인터뷰 (정남이 이사 포함)</span>
        </motion.div>
      </motion.div>
      <Source>출처 · Microsoft Work Trend Index · ARCA 자체 인터뷰 (2026 상반기, n=40)</Source>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S4 — FIELD SIGNAL: 40명+ 인터뷰
   ──────────────────────────────────────────────────────────── */
const cohort = ["창업자", "직장인", "VC·심사역", "ZER01NE"];

function Slide04Field(_: SlideProps) {
  return (
    <section className="slide slide--glow hy-field">
      <div className="hy-field-left">
        <Header
          eyebrow="03 FIELD SIGNAL"
          title={<>40명+ 인터뷰.<br />같은 문장이 반복됐습니다.</>}
          sub="더 긴 요약이 아니라, 바로 쓸 수 있는 후속조치 묶음이 필요했습니다."
        />
        <motion.figure
          className="hy-quote-card"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.45, ease: EASE_OUT }}
        >
          <blockquote>
            "매니저들이 VC를 직접 기억에서 꺼내 매칭한다.
            그 맥락을 공유할 LLM이 절실하다."
          </blockquote>
          <figcaption>
            <img
              src={`${A}/brand/asan-nanum.png`}
              alt="아산나눔재단"
              className="hy-asan-logo"
              loading="lazy"
            />
            정남이 이사 · 아산나눔재단 마루 (VC 매칭)
          </figcaption>
        </motion.figure>
        <p className="hy-field-note">
          가장 똑똑한 운영자조차 정보가 <b>머릿속에만</b> 있고, 꺼낼 시스템이 없습니다.
        </p>
      </div>
      <div className="hy-field-right">
        <div className="hy-field-photo hy-photo hy-photo--overlay" role="img" aria-label="아산 인터뷰 현장">
          <img src={`${A}/photos/asan-jeong.jpg`} alt="정남이 이사 인터뷰 현장" loading="lazy" />
        </div>
        <motion.div className="hy-cohort-board" variants={stagger(0.08, 0.3)} initial="hidden" animate="show">
          <motion.strong variants={scaleIn}>40+</motion.strong>
          {cohort.map((item) => (
            <motion.span key={item} variants={fadeUp}>{item}</motion.span>
          ))}
        </motion.div>
      </div>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S5 — FUNDING LANDSCAPE (with brand logos)
   ──────────────────────────────────────────────────────────── */
const fundingCards = [
  { name: "Bond", domain: "bondapp.io", meta: "YC X25 · Fellows Fund", amount: "$3M", krw: "≈ 41억원", note: "시드 (2025.12)" },
  { name: "Dimension", domain: "dimension.dev", meta: "GitHub·Vercel·Framer 창업자", amount: "$2M+", krw: "≈ 28억원", note: "출시 전 X 임팩션 350만" },
  { name: "a16z", domain: "a16z.com", meta: "공개 모집", amount: "AI CoS", krw: "Chief of Staff", note: "실리콘밸리 최다 회자 롤" },
  { name: "YC", domain: "ycombinator.com", meta: "Request for Startups", amount: "×2", krw: "company brain", note: '"company OS"를 두 번 요청', fallbackBg: "#FB651E", fallbackColor: "#fff" },
];

function Slide05Funding(_: SlideProps) {
  return (
    <section className="slide slide--glow hy-funding">
      <Header
        eyebrow="04 FUNDING LANDSCAPE"
        title={<>AI Chief of Staff 카테고리에<br /><span className="deck-accent">자본이 집중되고 있습니다.</span></>}
      />
      <motion.div className="hy-fund-grid" variants={stagger(0.1, 0.28)} initial="hidden" animate="show">
        {fundingCards.map((c) => (
          <motion.div key={c.name} variants={fadeUp} className="hy-fund-card">
            <div className="hy-fund-header">
              <BrandLogo name={c.name} domain={c.domain} fallbackBg={c.fallbackBg} fallbackColor={c.fallbackColor} size={44} />
              <span className="hy-fund-name">{c.name}</span>
            </div>
            <b className="hy-fund-amount">{c.amount}</b>
            <em className="hy-fund-krw">{c.krw}</em>
            <small className="hy-fund-meta">{c.meta}</small>
            <small className="hy-fund-note">{c.note}</small>
          </motion.div>
        ))}
      </motion.div>
      <Honesty tone="warn">
        <b>Dimension은 2026.5 폐업.</b> 잘 만들고·펀딩받고·띄웠는데도 ~6개월 만에 종료.
        죽은 이유 = <i>아무도 습관 들이지 않은 수동 브리핑.</i>{" "}
        시장은 뜨겁고(hot) 동시에 어렵다(hard). ARCA는 그 반대 = <b className="deck-accent">능동 ritual + 루프를 닫는 실행.</b>
      </Honesty>
      <Source>출처 · Bond (YC launch · Fellows Fund) · Dimension (PitchBook · winding-down) · Bond 창업자 에세이 2026.5 (a16z·YC RFS)</Source>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S6 — WEDGE: v1 = Slack + 회의
   ──────────────────────────────────────────────────────────── */
function Slide06Wedge(_: SlideProps) {
  return (
    <section className="slide slide--glow hy-wedge">
      <Header
        eyebrow="05 WEDGE"
        title={<>하드웨어도, 마켓플레이스도 아닙니다.<br /><span className="deck-accent">v1은 Slack + 회의 후속조치.</span></>}
        sub="긴 요약 X → 후속조치 묶음 O · 전부 자동화 X → 자동/승인 분리 O · 비전 너무 넓었음 → 하나로 좁혔습니다."
      />
      <motion.div className="hy-funnel" variants={stagger(0.12, 0.36)} initial="hidden" animate="show">
        {["메시지 / 회의", "Action Pack", "승인 또는 위임", "닫힌 업무 루프"].map((step, i) => (
          <motion.div key={step} variants={fadeUp} className={i === 3 ? "is-final" : ""}>
            <span>{String(i + 1).padStart(2, "0")}</span>
            <b>{step}</b>
          </motion.div>
        ))}
      </motion.div>
      <Honesty tone="muted">
        이 피봇은 <b>ZER01NE 스프린트 도중</b>에 일어났습니다. PMF는 하드웨어가 아니라
        <b className="deck-accent"> 업무 루프가 닫히는 경험</b>에서 검증합니다.
      </Honesty>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S7 — DEMO: Action Pack 5요소 + video
   ──────────────────────────────────────────────────────────── */
const actionPack = [
  { no: "01", label: "대화 요약", body: "회의 목적, 참석자, 준비물 요구사항을 한 문단으로 압축" },
  { no: "02", label: "해야 할 일", body: "자료 취합, 초대 발송, 담당자 확인을 액션으로 분리" },
  { no: "03", label: "캘린더 초안", body: "내일 14:00 데모 준비 회의 초안 생성" },
  { no: "04", label: "답장 초안", body: "참석자에게 보낼 준비물 메일과 Slack 문장 작성" },
  { no: "05", label: "추적 기록", body: "팀의 다음 상태로 남아 다시 물어보지 않게 저장" },
];

function Slide07Demo(_: SlideProps) {
  return (
    <section className="slide hy-demo">
      <Header
        eyebrow="06 LIVE DEMO"
        title={<>데모에서 볼 것은 하나입니다.<br /><span className="deck-accent">요청 하나가 Action Pack으로 바뀌는가.</span></>}
      />
      <div className="hy-demo-body">
        <motion.div
          className="hy-demo-console"
          initial={{ opacity: 0, scale: 0.97 }}
          animate={{ opacity: 1, scale: 1 }}
          transition={{ delay: 0.3, ease: EASE_OUT }}
        >
          <div className="hy-demo-console-top">
            <span>ARCA</span>
            <b>arca it</b>
          </div>
          <div className="hy-demo-request">
            <small>요청</small>
            <p>내일 2시 데모 준비 회의 잡고, 참석자에 준비물 메일, 액션 아이템 기록해줘.</p>
          </div>
          <span className="hy-demo-badge">arca it</span>
          <div className="hy-demo-progress" aria-label="ARCA processing steps">
            {["캘린더 확인", "참석자 정리", "메일 초안", "액션 기록"].map((step, idx) => (
              <span key={step} className={idx === 3 ? "is-live" : ""}>{step}</span>
            ))}
          </div>
        </motion.div>
        <div className="hy-demo-right">
          <motion.div className="hy-pack" variants={stagger(0.09, 0.4)} initial="hidden" animate="show">
            {actionPack.map((item) => (
              <motion.div variants={fadeUp} key={item.no} className="hy-pack-card">
                <span>{item.no}</span>
                <b>{item.label}</b>
                <p>{item.body}</p>
              </motion.div>
            ))}
          </motion.div>
          <p className="hy-demo-proof">승인 1회 - 캘린더, 메일, 팀 기록을 한 번에 실행</p>
        </div>
      </div>
      <motion.p
        className="hy-demo-line"
        initial={{ opacity: 0, y: 18 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.9, ease: EASE_OUT }}
      >
        "내일 2시 데모 준비 회의 잡고, 참석자에 준비물 메일, 액션 아이템 기록해줘."
        <em> AI가 말 잘하는 게 아니라, 내가 안 건드려도 일이 다음 단계로 넘어갔다.</em>
      </motion.p>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S8 — CATEGORY: handoff (2x2)
   ──────────────────────────────────────────────────────────── */
function Slide08Category({ active }: SlideProps) {
  return (
    <section className="slide slide--glow hy-category">
      <Header
        eyebrow="07 CATEGORY"
        title={<>요약은 견적서를 보내지 않습니다.<br />ARCA는 <span className="deck-accent">handoff</span>입니다.</>}
        sub={'\'정리해줘\'가 아니라 \'이 일을 끝내줘.\' 핵심 지표 = 닫힌 업무 루프 수.'}
      />
      <div className="hy-matrix">
        <span className="hy-axis hy-axis-y">몰입 보호 ↑</span>
        <span className="hy-axis hy-axis-x">업무 완료 →</span>
        {[
          { cls: "muted", l: "20%", t: "68%", d: 0.35, t1: "요약앱", t2: "Granola · Otter · CLOVA" },
          { cls: "muted", l: "48%", t: "58%", d: 0.55, t1: "범용 에이전트", t2: "책임 경계가 흐림" },
          { cls: "human", l: "64%", t: "26%", d: 0.75, t1: "사람 비서", t2: "비싸고 느림" },
          { cls: "arca", l: "82%", t: "14%", d: 0.98, t1: "ARCA", t2: "승인 가능한 위임" },
        ].map((p) => (
          <motion.div
            key={p.t1}
            className={`hy-dot ${p.cls}`}
            style={{ left: p.l, top: p.t }}
            initial={{ scale: 0, opacity: 0 }}
            animate={active ? { scale: 1, opacity: 1 } : { scale: 0, opacity: 0 }}
            transition={{ delay: p.d, ease: EASE_OUT }}
          >
            {p.t1}<span>{p.t2}</span>
          </motion.div>
        ))}
      </div>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S9 — COMPETITOR MATRIX TABLE (with logos)
   ──────────────────────────────────────────────────────────── */
const matrixCols = [
  { label: "ARCA", domain: undefined },
  { label: "Bond", domain: "bondapp.io" },
  { label: "Dimension†", domain: "dimension.dev" },
  { label: "요약앱", domain: undefined },
  { label: "Suite", domain: undefined },
];
const matrixRows: { label: string; cells: string[]; bold?: boolean }[] = [
  { label: "카테고리", cells: ["위임/handoff", "to-do 트리아지", "AI coworker", "기록·요약", "suite 어시"] },
  { label: "후속조치 실행 (루프 닫기)", cells: ["◎", "○", "○ 초안", "✕", "△"] },
  { label: "캡처 레이어 (하드웨어)", cells: ["◎ HW", "✕", "✕", "✕", "✕"], bold: true },
  { label: "컴패니언 / delight", cells: ["◎", "✕", "✕", "✕", "✕"], bold: true },
  { label: "실시간 집중 보호 (ZONE)", cells: ["◎", "✕", "✕", "✕", "✕"] },
  { label: "신뢰 3단계 명시 (H/D/E)", cells: ["◎", "△", "△", "—", "△"] },
  { label: "네이티브 데스크톱 (메뉴바)", cells: ["◎ macOS", "✕ Slack", "✕ 웹", "△", "✕"] },
  { label: "월 가격", cells: ["12,900원", "$99 ≈ 13.7만", "$29–199", "제각각", "suite 포함"] },
  { label: "상태", cells: ["데모 작동", "베타", "2026.5 폐업", "운영", "운영"] },
];

function symClass(s: string) {
  if (s.startsWith("◎")) return "is-full";
  if (s.startsWith("○")) return "is-mid";
  if (s.startsWith("△")) return "is-low";
  if (s.startsWith("✕")) return "is-none";
  return "";
}

function Slide09Matrix(_: SlideProps) {
  return (
    <section className="slide hy-compete">
      <Header
        eyebrow="08 COMPETITION"
        title={<>같은 문제, 다른 깊이.<br /><span className="deck-accent">우리는 두 레인을 더 가집니다.</span></>}
      />
      <motion.div
        className="hy-table-wrap"
        initial={{ opacity: 0, y: 18 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.3, ease: EASE_OUT }}
      >
        <table className="hy-table">
          <thead>
            <tr>
              <th className="hy-th-label">기준</th>
              {matrixCols.map((c) => (
                <th key={c.label} className={c.label === "ARCA" ? "is-arca" : ""}>
                  {c.domain ? (
                    <span className="hy-th-logo">
                      <BrandLogo name={c.label} domain={c.domain} />
                      <span>{c.label}</span>
                    </span>
                  ) : c.label}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {matrixRows.map((row) => (
              <tr key={row.label} className={row.bold ? "is-bold" : ""}>
                <td className="hy-td-label">{row.label}</td>
                {row.cells.map((cell, ci) => (
                  <td key={ci} className={`${ci === 0 ? "is-arca " : ""}${symClass(cell)}`}>{cell}</td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </motion.div>
      <div className="hy-compete-foot">
        <div className="hy-legend">
          <span><i className="is-full">◎</i> 강</span>
          <span><i className="is-mid">○</i> 중</span>
          <span><i className="is-low">△</i> 약</span>
          <span><i className="is-none">✕</i> 없음</span>
        </div>
        <Honesty tone="muted">
          굵은 두 행(<b>캡처 HW · 컴패니언</b>) = 경쟁사 전원 ✕ = ARCA만의 화이트스페이스.{" "}
          Bond은 exec·CoS 워크플로우 타깃, ARCA는 IC 후속조치 타깃.{" "}
          <b className="deck-accent">같은 일 1/10이 아닌, 더 큰 IC 시장을 더 싸게.</b>{" "}
          (Bond 13.7만원 vs ARCA 12,900원)
        </Honesty>
      </div>
      <Source>출처 · 각 사 공식 가격/제품 페이지 · 자체 teardown (docs/research/)</Source>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S10 — CONTEXT LOOP (맥락을 쌓는 AI)
   ──────────────────────────────────────────────────────────── */
function Slide10Loop({ active }: SlideProps) {
  return (
    <section className="slide hy-loop">
      <Header
        eyebrow="09 CONTEXT LOOP"
        title={<>맥락을 쌓는 AI.<br /><span className="deck-accent">루프를 돌수록, 당신의 일을 더 잘 압니다.</span></>}
      />
      <div className="hy-loop-outer">
        <ContextLoopDiagram active={active} />
        <motion.div
          className="hy-loop-proof"
          initial={{ opacity: 0, x: 20 }}
          animate={{ opacity: 1, x: 0 }}
          transition={{ delay: 0.5, ease: EASE_OUT }}
        >
          <img
            src={`${A}/photos/demo/demo-1.png`}
            alt="ARCA Memory — 맥락 축적 화면"
            loading="lazy"
            className="hy-loop-proof-img"
          />
          <p className="hy-loop-proof-cap">실제 ARCA Memory<br />Obsidian · Gmail · Slack에서 맥락 축적</p>
        </motion.div>
      </div>
      <motion.div
        className="hy-audit-strip"
        initial={{ opacity: 0, scaleX: 0 }}
        animate={{ opacity: 1, scaleX: 1 }}
        transition={{ delay: 0.9, duration: 0.7, ease: EASE_OUT }}
      >
        저·중·고 위험 분기 · ARCA-assisted 표시 · audit log · 현재 보유: 암호화·학습미사용·로그 | SOC2·SSO·한국리전 = 기업 로드맵(미보유)
      </motion.div>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S11 — MARKET (GVR + 가설 SOM)
   ──────────────────────────────────────────────────────────── */
function Slide11Market({ active }: SlideProps) {
  return (
    <section className="slide slide--glow hy-market">
      <Header
        eyebrow="10 MARKET"
        title={<>큰 AI 시장이 아니라<br /><span className="deck-accent">지식노동 AI assistant</span>부터.</>}
        sub="GVR AI assistant software 기준. STT·LLM이 충분히 싸진 지금, 기록 앱 다음 카테고리가 열립니다."
      />
      <div className="hy-market-row">
        <motion.div initial={{ opacity: 0, y: 22 }} animate={{ opacity: 1, y: 0 }} transition={{ ease: EASE_OUT, delay: 0.25 }}>
          <b>$<AnimatedNumber value={8.46} decimals={2} suffix="B" play={active} /></b>
          <span>2024 market</span>
        </motion.div>
        <motion.div
          className="hy-market-arrow"
          initial={{ scaleX: 0 }}
          animate={{ scaleX: active ? 1 : 0 }}
          transition={{ duration: 0.8, delay: 0.55, ease: EASE_OUT }}
        />
        <motion.div initial={{ opacity: 0, y: 22 }} animate={{ opacity: 1, y: 0 }} transition={{ ease: EASE_OUT, delay: 0.45 }}>
          <b>$<AnimatedNumber value={35.7} decimals={1} suffix="B" play={active} /></b>
          <span>2033 forecast · CAGR ≈17%</span>
        </motion.div>
      </div>
      <motion.div
        className="hy-som-block"
        initial={{ opacity: 0, y: 14 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.8, ease: EASE_OUT }}
      >
        <span className="hy-som-tag">가설 SOM (90일 검증 대상)</span>
        <p>3년 내 유료 좌석 1만 → ARR 약 <b>15억원</b> <small>(개인 Pro 12,900원 기준)</small></p>
        <small>이 숫자는 가설입니다. 90일 파일럿이 검증·조정합니다.</small>
      </motion.div>
      <Source>출처 · Grand View Research, AI assistant software market · SOM은 자체 가설</Source>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S12 — PRICING + UNIT ECONOMICS
   ──────────────────────────────────────────────────────────── */
const cogs = [
  { label: "STT (batch)", basis: "ElevenLabs Scribe ~$0.22/h × 10h", value: 2.2, pct: 64.1 },
  { label: "LLM (라우팅)", basis: "저위험=저가모델 · 프런티어 선택적", value: 0.8, pct: 23.3 },
  { label: "결제 수수료", basis: "~3%", value: 0.28, pct: 8.2 },
  { label: "인프라·저장", basis: "벡터 · 스토리지 · 모니터링", value: 0.15, pct: 4.4 },
];

function Slide12Pricing({ active }: SlideProps) {
  return (
    <section className="slide hy-unit">
      <Header
        eyebrow="11 PRICING · UNIT ECONOMICS"
        title={<>가격은 단순하게,<br /><span className="deck-accent">마진은 계산해서.</span></>}
        sub="개인 Pro 12,900원 / 팀 19,900원. 월 10시간 기준 COGS $3.43 → Gross margin ≈63%."
      />
      <div className="hy-unit-body">
        <div className="hy-price-col">
          <div className="hy-price-chip">
            <span>개인 Pro</span><b>12,900<small>원/월</small></b><em>≈ $9.3</em>
          </div>
          <div className="hy-price-chip">
            <span>팀</span><b>19,900<small>원/좌석</small></b><em>한계 COGS 유사 → 마진↑</em>
          </div>
          <div className="hy-margin-gauge">
            <span>Gross margin</span>
            <b><AnimatedNumber value={63} suffix="%" play={active} /></b>
            <small>(9.3 − 3.43) / 9.3</small>
          </div>
        </div>
        <div className="hy-cogs">
          <div className="hy-cogs-head">
            <span>COGS 분해 · 월 10시간 기준</span>
            <b>$<AnimatedNumber value={3.43} decimals={2} play={active} /> <small>/ $9.3</small></b>
          </div>
          <div className="hy-cogs-bar">
            {cogs.map((c, i) => (
              <motion.div
                key={c.label}
                className={`hy-cogs-seg seg-${i}`}
                initial={{ width: 0 }}
                animate={{ width: active ? `${c.pct}%` : 0 }}
                transition={{ duration: 0.9, delay: 0.4 + i * 0.12, ease: EASE_OUT }}
                title={`${c.label} $${c.value}`}
              />
            ))}
            <motion.div
              className="hy-cogs-margin"
              initial={{ width: 0 }}
              animate={{ width: active ? "63%" : 0 }}
              transition={{ duration: 1.0, delay: 0.9, ease: EASE_OUT }}
            >
              margin 63%
            </motion.div>
          </div>
          <ul className="hy-cogs-legend">
            {cogs.map((c, i) => (
              <li key={c.label}>
                <i className={`seg-${i}`} />
                <span>{c.label}</span>
                <em>{c.basis}</em>
                <b>${c.value.toFixed(2)}</b>
              </li>
            ))}
          </ul>
        </div>
      </div>
      <Honesty tone="warn">
        WTP는 <b>검증 전.</b> STT는 사용시간에 선형 ↑ → 월 30h↑ 헤비유저는{" "}
        <b>마진이 깨집니다 → 사용량 캡 / 팀 전환.</b>{" "}
        이 $3 COGS 라인이 다음 검증 기준.
      </Honesty>
      <Source>출처 · ElevenLabs Scribe 공식 단가 · 모델 라우팅 가정(검증 대상) · 1 USD ≈ 1,380 KRW</Source>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S13 — BUSINESS MODEL: 4가지로 복리됩니다
   SVG icons adapted from ir/arca-pitch.html lines 370/378/384/395
   v1 = ① 구독 (지금 검증), ②③④ = 복리 확장 로드맵
   ──────────────────────────────────────────────────────────── */
function Slide13BizModel(_: SlideProps) {
  return (
    <section className="slide slide--glow hy-biz">
      <Header
        eyebrow="12 BUSINESS MODEL"
        title={<>구독으로 시작해,<br /><span className="deck-accent">맥락 위에 복리됩니다.</span></>}
        sub="v1 = ① 구독 웨지 (지금 검증). ②③④ = 복리 확장 로드맵."
      />
      <motion.div className="hy-biz-grid" variants={stagger(0.1, 0.28)} initial="hidden" animate="show">
        {/* ① 구독 */}
        <motion.div variants={fadeUp} className="hy-biz-col hy-biz-col--active">
          <div className="hy-biz-ill">
            <svg viewBox="0 0 120 96" width="80" fill="none">
              <g stroke="var(--accent)" strokeWidth="2.5" strokeLinecap="round">
                <line x1="16" y1="48" x2="16" y2="58"/><line x1="26" y1="40" x2="26" y2="66"/><line x1="36" y1="30" x2="36" y2="76"/>
              </g>
              <rect x="52" y="20" width="20" height="40" rx="10" fill="rgba(255,122,26,0.25)" stroke="var(--accent)" strokeWidth="1.5"/>
              <path d="M44 50 a18 18 0 0 0 36 0" stroke="var(--copper)" strokeWidth="2.5" fill="none"/>
              <line x1="62" y1="68" x2="62" y2="78" stroke="var(--copper)" strokeWidth="2.5" strokeLinecap="round"/>
              <g stroke="var(--accent)" strokeWidth="2.5" strokeLinecap="round">
                <line x1="88" y1="40" x2="88" y2="66"/><line x1="98" y1="48" x2="98" y2="58"/><line x1="108" y1="44" x2="108" y2="62"/>
              </g>
            </svg>
          </div>
          <div className="hy-biz-badge-row">
            <span className="hy-biz-num">①</span>
            <span className="hy-biz-badge hy-biz-badge--now">v1 · 지금 검증</span>
          </div>
          <b className="hy-biz-title">구독</b>
          <p className="hy-biz-desc">전사 + 루프를 닫는 에이전트.</p>
          <div className="hy-biz-price-row"><span>개인 Pro</span><b>12,900원</b><small>/월</small></div>
          <div className="hy-biz-price-row"><span>팀</span><b>19,900원</b><small>/좌석</small></div>
        </motion.div>
        {/* ② 하드웨어 */}
        <motion.div variants={fadeUp} className="hy-biz-col hy-biz-col--road">
          <div className="hy-biz-ill">
            <svg viewBox="0 0 120 110" width="64" fill="none">
              <ellipse cx="60" cy="100" rx="32" ry="6" fill="#000" opacity=".25"/>
              <rect x="18" y="14" width="84" height="84" rx="34" fill="rgba(255,122,26,0.2)" stroke="var(--accent)" strokeWidth="1.5"/>
              <circle cx="48" cy="50" r="5.5" fill="#2A1205"/><circle cx="72" cy="50" r="5.5" fill="#2A1205"/>
              <circle cx="46" cy="47" r="1.8" fill="#fff"/><circle cx="70" cy="47" r="1.8" fill="#fff"/>
              <path d="M50 64 Q60 74 70 64" stroke="#2A1205" strokeWidth="3" fill="none" strokeLinecap="round"/>
            </svg>
          </div>
          <div className="hy-biz-badge-row">
            <span className="hy-biz-num">②</span>
            <span className="hy-biz-badge">확장</span>
          </div>
          <b className="hy-biz-title">하드웨어 코어</b>
          <p className="hy-biz-desc">한 버튼, 항상 켜진 현실 대화 캡처.</p>
          <div className="hy-biz-price-row"><span>캡처 디바이스</span><b>18–25만원</b></div>
        </motion.div>
        {/* ③ 쉘·액세서리 */}
        <motion.div variants={fadeUp} className="hy-biz-col hy-biz-col--road">
          <div className="hy-biz-ill">
            <div className="hy-biz-shells">
              <svg viewBox="0 0 64 68" width="28" fill="none">
                <path d="M14 56 h36 l7 9 h-50 z" fill="rgba(255,122,26,0.15)" stroke="rgba(255,237,215,0.25)" strokeWidth="1.5"/>
                <rect x="20" y="12" width="28" height="42" rx="13" fill="rgba(255,122,26,0.25)" stroke="var(--accent)" strokeWidth="1.5"/>
                <circle cx="29" cy="32" r="2.2" fill="#2A1205"/><circle cx="40" cy="32" r="2.2" fill="#2A1205"/>
              </svg>
              <svg viewBox="0 0 64 66" width="28" fill="none">
                <path d="M18 20 L13 4 L27 13 Z" fill="rgba(255,122,26,0.3)"/><path d="M46 20 L51 4 L37 13 Z" fill="rgba(255,122,26,0.3)"/>
                <rect x="15" y="14" width="34" height="42" rx="16" fill="rgba(255,122,26,0.25)" stroke="var(--accent)" strokeWidth="1.5"/>
                <circle cx="27" cy="34" r="2.5" fill="#2A1205"/><circle cx="41" cy="34" r="2.5" fill="#2A1205"/>
              </svg>
              <svg viewBox="0 0 64 72" width="28" fill="none">
                <circle cx="34" cy="12" r="7" fill="none" stroke="var(--accent)" strokeWidth="2.5"/>
                <rect x="20" y="22" width="28" height="42" rx="13" fill="rgba(255,122,26,0.25)" stroke="var(--accent)" strokeWidth="1.5"/>
                <circle cx="29" cy="42" r="2.4" fill="#2A1205"/><circle cx="39" cy="42" r="2.4" fill="#2A1205"/>
              </svg>
            </div>
          </div>
          <div className="hy-biz-badge-row">
            <span className="hy-biz-num">③</span>
            <span className="hy-biz-badge">확장</span>
          </div>
          <b className="hy-biz-title">쉘·액세서리</b>
          <p className="hy-biz-desc">케이스 + 피규어 + 웨어러블 시장을 하나로.</p>
          <div className="hy-biz-price-row"><span>스탠드·캐릭터·키링</span><b>2–6만원</b></div>
        </motion.div>
        {/* ④ 마켓플레이스 */}
        <motion.div variants={fadeUp} className="hy-biz-col hy-biz-col--future">
          <div className="hy-biz-ill">
            <svg viewBox="0 0 130 92" width="80" fill="none">
              <circle cx="40" cy="46" r="20" fill="rgba(255,122,26,0.12)" stroke="var(--copper)" strokeWidth="1.5"/>
              <text x="40" y="46" textAnchor="middle" dominantBaseline="central" fontSize="18">🧠</text>
              <line x1="60" y1="40" x2="78" y2="40" stroke="var(--accent)" strokeWidth="2.5" strokeLinecap="round"/>
              <line x1="60" y1="52" x2="78" y2="52" stroke="var(--accent)" strokeWidth="2.5" strokeLinecap="round"/>
              <rect x="78" y="30" width="34" height="32" rx="7" fill="rgba(255,122,26,0.2)" stroke="var(--accent)" strokeWidth="1.5"/>
              <text x="95" y="46" textAnchor="middle" dominantBaseline="central" fontSize="14">⚙️</text>
            </svg>
          </div>
          <div className="hy-biz-badge-row">
            <span className="hy-biz-num">④</span>
            <span className="hy-biz-badge hy-biz-badge--future">FUTURE</span>
          </div>
          <b className="hy-biz-title">하네스 마켓플레이스</b>
          <p className="hy-biz-desc">전문가가 워크플로를 팔고, 우리가 수수료.</p>
          <div className="hy-biz-price-row"><span>take-rate</span></div>
        </motion.div>
      </motion.div>
      <motion.p className="hy-biz-close" initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: 1.1, duration: 0.7 }}>
        구독으로 시작해, 맥락 위에 복리됩니다 — 하드웨어·쉘·마켓플레이스로.
      </motion.p>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S14 (prev S13) — TRACTION vs RISK
   ──────────────────────────────────────────────────────────── */
const real = [
  "작동하는 macOS 프로토타입",
  "회의·음성 → Action Pack · 메모리 저장 · 데모 ingest 연결",
  "waitlist 50명+ (연세대 UIC 총장 포함)",
  "40명 인터뷰 + ZER01NE 피드백 → v1 좁힘",
];
const notYet = [
  "유료 사용자 / 유지율 데이터 없음",
  "WTP 검증 전 (설문 설계만 완료)",
];

function Slide13Traction(_: SlideProps) {
  return (
    <section className="slide slide--glow hy-traction">
      <Header
        eyebrow="12 TRACTION vs RISK"
        title={<>진짜인 것과 아직 아닌 것을<br /><span className="deck-accent">나눠서 보여드립니다.</span></>}
      />
      <div className="hy-traction-outer">
        <div className="hy-traction-grid">
          <motion.div className="hy-col hy-col--real" variants={stagger(0.1, 0.3)} initial="hidden" animate="show">
            <motion.h3 variants={fadeUp}>진짜인 것</motion.h3>
            {real.map((r) => (
              <motion.div key={r} variants={fadeUp} className="hy-tr-item">
                <i>✓</i><span>{r}</span>
              </motion.div>
            ))}
          </motion.div>
          <motion.div className="hy-col hy-col--risk" variants={stagger(0.1, 0.5)} initial="hidden" animate="show">
            <motion.h3 variants={fadeUp}>아직 아닌 것</motion.h3>
            {notYet.map((r) => (
              <motion.div key={r} variants={fadeUp} className="hy-tr-item">
                <i>—</i><span>{r}</span>
              </motion.div>
            ))}
            <motion.div variants={fadeUp} className="hy-risk-note">
              이것이 다음 90일의 과녁입니다.
            </motion.div>
          </motion.div>
        </div>
        {/* proof photos */}
        <motion.div
          className="hy-traction-photos"
          variants={stagger(0.1, 0.5)}
          initial="hidden"
          animate="show"
        >
          <motion.div variants={fadeUp} className="hy-proof-photo">
            <img src={`${A}/photos/waitlist.jpg`} alt="waitlist 등록 현장" loading="lazy" />
            <span>waitlist 등록 현장</span>
          </motion.div>
          <motion.div variants={fadeUp} className="hy-proof-photo">
            <img src={`${A}/photos/booth.jpg`} alt="ZER01NE 부스 — qbit 디바이스 + 방문자" loading="lazy" />
            <span>ZER01NE 부스</span>
          </motion.div>
        </motion.div>
      </div>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S14 — TEAM + VELOCITY BANNER
   ──────────────────────────────────────────────────────────── */
const teamMembers = [
  { name: "박민성", role: "Founder", detail: "제품 · 리서치 · macOS 프로토타입 · 데모 · 발표. 사용자 0번." },
  { name: "박진성", role: "하드웨어", detail: "서울대 기계공학 + 심리학적 사용 설계." },
  { name: "하승호", role: "임베디드", detail: "ISEF 임베디드 세계 2등 · Caltech 합격." },
];
const velocity = [
  { num: "2주", unit: "미만", label: "피봇 + 40인터뷰 + 작동 데모 + waitlist 50명+", photo: `${A}/photos/allnighter.jpg` },
  { num: "1주", unit: "미만", label: "데모 빌드", photo: `${A}/photos/velocity-build.jpg` },
  { num: "Sprint", unit: "도중", label: "ZER01NE 스프린트 도중 피봇", photo: `${A}/photos/booth.jpg` },
];

function Slide14Team(_: SlideProps) {
  return (
    <section className="slide hy-team">
      <Header
        eyebrow="13 TEAM"
        title={<>SW만이 아닙니다.<br /><span className="deck-accent">SW + HW/임베디드 + 심리설계</span> 한 팀.</>}
      />
      <div className="hy-team-body">
        {/* group photo — team.jpg: left=디자이너, center=박민성, right=하승호 */}
        <motion.div
          className="hy-team-photo"
          initial={{ opacity: 0, scale: 0.97 }}
          animate={{ opacity: 1, scale: 1 }}
          transition={{ delay: 0.2, ease: EASE_OUT }}
        >
          <img src={`${A}/photos/team.jpg`} alt="팀 스튜디오 촬영" loading="lazy" />
          <div className="hy-team-photo-labels">
            <span>디자이너</span>
            <span>박민성 · Founder</span>
            <span>하승호 · 임베디드</span>
          </div>
        </motion.div>
        {/* role cards */}
        <motion.div className="hy-team-roles" variants={stagger(0.1, 0.3)} initial="hidden" animate="show">
          {teamMembers.map((m) => (
            <motion.div key={m.name} variants={fadeUp} className="hy-member-card">
              <b>{m.name}</b>
              <span className="hy-member-role">{m.role}</span>
              <small>{m.detail}</small>
            </motion.div>
          ))}
        </motion.div>
      </div>
      {/* velocity photo strip */}
      <motion.div className="hy-velocity" variants={stagger(0.1, 0.5)} initial="hidden" animate="show">
        {velocity.map((v) => (
          <motion.div key={v.label} variants={scaleIn} className="hy-vel-item">
            <div className="hy-vel-photo">
              <img src={v.photo} alt={v.label} loading="lazy" />
            </div>
            <b>{v.num}<em>{v.unit}</em></b>
            <span>{v.label}</span>
          </motion.div>
        ))}
      </motion.div>
      <Honesty tone="muted">
        Bond · Dimension = SW 팀. <b className="deck-accent">우리 = 한 팀이 캡처 HW와 컴패니언 UX를 둘 다 직접.</b>
        파는 건 아이디어가 아니라 실행 속도.
      </Honesty>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S15 — 성장전략 (GTM ladder — 개인 → 팀 → 기업)
   ──────────────────────────────────────────────────────────── */
function Slide15GTM(_: SlideProps) {
  return (
    <section className="slide slide--glow hy-gtm">
      <Header
        eyebrow="14 GROWTH STRATEGY"
        title={<>대기업 계약부터 가지 않습니다.<br /><span className="deck-accent">강한 개인 사용에서 팀으로 번집니다.</span></>}
        sub="bottom-up: 개인이 먼저 습관을 만들고, 팀이 도입하고, 기업이 따릅니다."
      />
      <motion.div className="hy-gtm-ladder" variants={stagger(0.13, 0.36)} initial="hidden" animate="show">
        {[
          { step: "01", who: "개인", desc: "지식노동자 Pro 12,900원 — 반복 위임 습관 형성", tag: "현재" },
          { step: "02", who: "팀", desc: "B2B 유료 파일럿 3팀 · LOI — 팀 단위 루프 확인", tag: "90일" },
          { step: "03", who: "기업", desc: "IT 계약 + 온보딩 — 개인이 이미 쓰는 도구로 진입", tag: "다음 라운드" },
        ].map((r) => (
          <motion.div key={r.step} variants={fadeUp} className="hy-gtm-row">
            <span className="hy-gtm-step">{r.step}</span>
            <b className="hy-gtm-who">{r.who}</b>
            <p className="hy-gtm-desc">{r.desc}</p>
            <span className="hy-gtm-tag">{r.tag}</span>
          </motion.div>
        ))}
      </motion.div>
      <Honesty tone="muted">
        대기업 계약부터 가지 않는 이유: 습관 없이 IT 계약만 따내면 유지율로 죽습니다.
        개인 반복 사용이 팀 도입의 근거입니다. Copilot·Notion AI = suite에 갇힘.
        <b className="deck-accent"> ARCA는 도구를 가로질러 후속조치를 닫습니다.</b>
      </Honesty>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S16 — ASK 2억 (make it the biggest element)
   ──────────────────────────────────────────────────────────── */
const allocation = [
  { label: "인재", pct: 45, krw: "9,000만", note: "사용성·리텐션(최대 리스크) · delight UX 10x" },
  { label: "하드웨어", pct: 30, krw: "6,000만", note: "캡처 디바이스 프로토타입 · 외주 의존↓" },
  { label: "런웨이", pct: 25, krw: "5,000만", note: "STT·LLM·인프라 · B2B 파일럿 운영" },
];

function Slide16Ask({ active }: SlideProps) {
  return (
    <section className="slide slide--glow hy-ask">
      <Header
        eyebrow="15 ASK"
        title={<>핵심 가설을 90일 안에<br /><span className="deck-accent">죽이거나 살립니다.</span></>}
      />
      <motion.div
        className="hy-ask-hero"
        initial={{ opacity: 0, scale: 0.85 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ delay: 0.2, ease: EASE_OUT, duration: 0.7 }}
      >
        <span className="hy-ask-amount">2억원</span>
        <span className="hy-ask-label">pre-seed</span>
      </motion.div>
      <div className="hy-alloc">
        <div className="hy-alloc-bar">
          {allocation.map((a, i) => (
            <motion.div
              key={a.label}
              className={`hy-alloc-seg alloc-${i}`}
              initial={{ width: 0 }}
              animate={{ width: active ? `${a.pct}%` : 0 }}
              transition={{ duration: 0.9, delay: 0.5 + i * 0.14, ease: EASE_OUT }}
            >
              <b>{a.pct}%</b>
            </motion.div>
          ))}
        </div>
        <div className="hy-alloc-legend">
          {allocation.map((a, i) => (
            <div key={a.label} className="hy-alloc-item">
              <span className="hy-alloc-key"><i className={`alloc-${i}`} />{a.label}</span>
              <b>{a.krw}<small>원</small></b>
              <small>{a.note}</small>
            </div>
          ))}
        </div>
      </div>
      <motion.p
        className="hy-ask-line"
        initial={{ opacity: 0, y: 16 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 1.2, ease: EASE_OUT }}
      >
        회사 키우는 돈이 아니라, <b>90일 안에 핵심 가설을 죽이거나 살리는 돈.</b>
      </motion.p>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S17 — NEXT 90 DAYS
   ──────────────────────────────────────────────────────────── */
function Slide17Next(_: SlideProps) {
  return (
    <section className="slide slide--glow hy-next">
      <Header
        eyebrow="16 NEXT 90 DAYS"
        title={<>다음 90일, 우리가 답할<br /><span className="deck-accent">질문은 하나입니다.</span></>}
        sub="돈 내고 위임하는 습관을 만들 수 있는가?"
      />
      <motion.div className="hy-90" variants={stagger(0.12, 0.36)} initial="hidden" animate="show">
        {[
          ["B2B 3팀", "유료 파일럿 또는 LOI"],
          ["100", "반복 사용자"],
          ["루프", "사용자당 주당 닫힌 수"],
          ["LOI ≥1", "결제 또는 파일럿"],
        ].map(([num, label]) => (
          <motion.div key={label} variants={scaleIn}>
            <b>{num}</b>
            <span>{label}</span>
          </motion.div>
        ))}
      </motion.div>
      <motion.p
        className="hy-close-line"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ delay: 1.0, duration: 0.8 }}
      >
        여기까지 = 아이디어가 아니라 다음 라운드 검토 가능한 회사.
      </motion.p>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S18 — ROADMAP: 12개월 swim-lane timeline
   ──────────────────────────────────────────────────────────── */
const PHASES = [
  { label: "0–90일", sub: "웨지 검증", now: true },
  { label: "3–6개월", sub: "창업자 100명 + SF", now: false },
  { label: "6–9개월", sub: "팀 제품화", now: false },
  { label: "9–12개월", sub: "스케일 → 시드", now: false },
];
const LANES: { label: string; icon: string; cells: (string | null)[] }[] = [
  {
    label: "고객 · GTM",
    icon: "🎯",
    cells: [
      "B2B 파일럿 3팀\n반복 100명 · LOI≥1",
      "창업자 100명\nSlack 임베드 · SF 현장\n10·50인 팀 PoC",
      "PoC 학습 →\n팀 과금(19,900/좌석) 검증",
      "유료 팀 확대\nARR run-rate",
    ],
  },
  {
    label: "제품",
    icon: "⚙️",
    cells: [
      "Action Pack 안정화\n닫힌 루프 지표",
      "팀 컨텍스트 코어\n완수 데이터 축적",
      "신뢰·보안\naudit · RBAC · 리전",
      "유지율 ↔\n닫힌 루프 증명",
    ],
  },
  {
    label: "하드웨어",
    icon: "🔷",
    cells: [
      null,
      "캡처 디바이스\n프로토타입",
      "알파\n현실 대화 캡처",
      "코어 베타 + 쉘 1차\n마켓플레이스 알파",
    ],
  },
  {
    label: "팀 · 자금",
    icon: "👥",
    cells: [
      "크래프톤 게임개발자\n영입(UX)",
      null,
      "핵심 엔지니어\n보강",
      "시드 라운드\n(지표 기반)",
    ],
  },
];

function Slide_Roadmap(_: SlideProps) {
  return (
    <section className="slide slide--glow hy-roadmap">
      <motion.div variants={stagger(0.08, 0.08)} initial="hidden" animate="show" className="hy-head hy-rm-head">
        <motion.p variants={fadeUp} className="deck-eyebrow">18 ROADMAP</motion.p>
        <motion.h2 variants={blurUp} className="deck-h2 hy-rm-h2">다음 12개월.</motion.h2>
        <motion.p variants={fadeUp} className="hy-sub hy-rm-sub">좁은 웨지에서 팀으로, 그리고 복리로.</motion.p>
      </motion.div>

      {/* swim-lane grid */}
      <motion.div
        className="hy-rm-grid"
        initial={{ opacity: 0, y: 12 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.3, ease: EASE_OUT }}
      >
        {/* header row: phase columns */}
        <div className="hy-rm-corner" />
        {PHASES.map((p) => (
          <div key={p.label} className={`hy-rm-phase-head${p.now ? " hy-rm-phase-head--now" : ""}`}>
            <b>{p.label}</b>
            <span>{p.sub}</span>
            {p.now && <em>지금</em>}
          </div>
        ))}
        {/* lane rows */}
        {LANES.map((lane, li) => (
          <>
            <div key={`lane-${li}`} className="hy-rm-lane-label">
              <span>{lane.icon}</span>
              <b>{lane.label}</b>
            </div>
            {lane.cells.map((cell, ci) => (
              <div
                key={`cell-${li}-${ci}`}
                className={`hy-rm-cell${ci === 0 ? " hy-rm-cell--now" : ""}${cell === null ? " hy-rm-cell--empty" : ""}`}
              >
                {cell ? cell.split("\n").map((line, idx) => (
                  <span key={idx}>{line}</span>
                )) : <span className="hy-rm-dash">—</span>}
              </div>
            ))}
          </>
        ))}
      </motion.div>

      {/* anchor line */}
      <motion.p
        className="hy-rm-anchor"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ delay: 0.45, duration: 0.5 }}
      >
        핵심은 하나 — 창업자 100명의 Slack·소통체계 안에 들어가,{" "}
        <b>10·50인 팀이 진짜 원하는 걸 밀접 PoC로 알아낸다.</b>
      </motion.p>

      {/* playbook band */}
      <motion.div
        className="hy-rm-playbook"
        initial={{ opacity: 0, y: 8 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.6, duration: 0.5 }}
      >
        <p className="hy-rm-playbook-eyebrow">접근 방식 · OUR PLAYBOOK</p>
        <div className="hy-rm-playbook-cols">
          <div className="hy-rm-pb-col">
            <b>빌드 인 퍼블릭</b>
            <span>다음 버전을 약속하지 않습니다. 매주 공개로 출시하고, 그 주에 닫은 루프를 전부 공개합니다.</span>
          </div>
          <div className="hy-rm-pb-col">
            <b>사용자 옆에서만 만듭니다</b>
            <span>회의실 로드맵은 죽습니다. 창업자 100명의 Slack 안에 살면서, 진짜 원하는 걸 직접 캡니다. SF로 건너갑니다.</span>
          </div>
          <div className="hy-rm-pb-col">
            <b>확장 안 되는 일부터</b>
            <span>첫 100명은 자동화로 안 모읍니다. 손으로 모읍니다.</span>
          </div>
        </div>
      </motion.div>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S19 — MOAT: 모델 성능은 해자가 아닙니다
   ──────────────────────────────────────────────────────────── */
function Slide18Moat(_: SlideProps) {
  const moats = [
    {
      num: "①",
      title: "완수 데이터",
      body: "누가 위임·승인·거절했는지, 무엇이 닫혔는지 — 업무방식 자체에 ARCA가 붙습니다.",
    },
    {
      num: "②",
      title: "신뢰 인터페이스",
      body: "뭘·왜·어디서 멈췄는지 보입니다. 불투명한 에이전트는 신뢰받지 못합니다.",
    },
    {
      num: "③",
      title: "습관 / 동사화",
      body: "\"요약해줘\" → \"arca 해놔\" = 기능이 아니라 행동입니다. 언어가 바뀌면 대체가 어렵습니다.",
    },
    {
      num: "+1",
      title: "캡처 HW + 컴패니언",
      body: "경쟁사 전원이 비운 레인. SW가 구조적으로 못 푸는 캡처 레이어 + delight.",
    },
  ];

  return (
    <section className="slide slide--glow hy-moat">
      <Header
        eyebrow="17 MOAT"
        title={<>모델 성능은 해자가 아닙니다.<br /><span className="deck-accent">MS·Google이 더 좋은 모델을 가질 수 있습니다.</span></>}
        sub="해자는 완수 데이터 · 신뢰 인터페이스 · 습관 동사 · 캡처 HW에서 옵니다."
      />
      <motion.div className="hy-moat-grid" variants={stagger(0.12, 0.3)} initial="hidden" animate="show">
        {moats.map((m) => (
          <motion.div key={m.num} variants={fadeUp} className="hy-moat-card">
            <span className="hy-moat-num">{m.num}</span>
            <b className="hy-moat-title">{m.title}</b>
            <p className="hy-moat-body">{m.body}</p>
          </motion.div>
        ))}
      </motion.div>
      <Honesty tone="muted">
        Copilot·Notion AI = suite 자기 생태계에 갇힘.{" "}
        <b className="deck-accent">ARCA는 도구를 가로질러 후속조치를 닫습니다.</b>{" "}
        루프를 돌수록 경쟁사가 따라오기 어려워집니다.
      </Honesty>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   S19 — CLOSE: arca 해놔
   ──────────────────────────────────────────────────────────── */
function Slide19Close(_: SlideProps) {
  return (
    <section className="slide slide--center hy-close">
      <motion.h2
        className="hy-close-mark"
        initial={{ opacity: 0, scale: 0.9, filter: "blur(12px)" }}
        animate={{ opacity: 1, scale: 1, filter: "blur(0px)" }}
        transition={{ duration: 1.1, ease: EASE_OUT }}
      >
        "arca 해놔."
      </motion.h2>
      <motion.p
        className="hy-close-label"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ delay: 0.6, duration: 0.6 }}
      >
        우리가 답할 질문
      </motion.p>
      <motion.blockquote
        className="hy-close-q"
        initial={{ opacity: 0, y: 18 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.9, ease: EASE_OUT }}
      >
        "이 팀이 좁은 업무 루프 하나를 끝까지 닫아,
        돈 내고 위임하는 습관을 만들 수 있는가."
      </motion.blockquote>
      <motion.p
        className="hy-close-ans"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ delay: 1.4, duration: 0.8 }}
      >
        다음 90일 안에 데이터로 답하겠습니다.
      </motion.p>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   APPENDIX A — Q&A 핵심 답변 그리드
   ──────────────────────────────────────────────────────────── */
const qanda = [
  { q: "왜 박민성인가", a: "이 문제의 사용자 0번. 제품·데모·리서치·배포를 직접 실행. solo 리스크 인정 → 박진성·하승호 팀 구성, 다음은 게임 개발자 영입." },
  { q: "왜 지금인가", a: "STT·LLM이 충분히 싸졌고, 사용자도 AI 초안·실행에 익숙. 기록 앱 다음 카테고리가 지금 열립니다." },
  { q: "누가 돈 내나", a: "초기엔 개인 지식노동자 Pro 12,900원. 팀 좌석 19,900원. 90일 핵심 지표 = 유료 의사 + 반복 사용." },
  { q: "MS·Notion·Granola가 하면", a: "요약 앱은 기록에서 멈추고, suite는 자기 생태계에 갇힘. ARCA는 도구를 가로질러 후속조치를 닫음. 해자 = 완수 데이터·신뢰 인터페이스·동사 습관 + 캡처 HW." },
  { q: "Bond이 먼저 했잖아", a: "같은 문제 검증한 건 시장 증거. Bond = SW-온리 + 미니멀 리스트. 그들이 비운 캡처 HW + 컴패니언 레인을 ARCA가 공략. Bond CEO가 직접 적은 약점(캡처 안 됨)." },
  { q: "AI 오발송 리스크", a: "저위험 자동, 중위험 초안+승인, 고위험 사람. 전 발신 ARCA-assisted 표시 + audit log." },
  { q: "하드웨어 꼭 필요한가", a: "v1 PMF는 SW로 검증. 하드웨어는 SW가 구조적으로 못 푸는 캡처 레이어 해자 + 이 팀이라 가능한 차별점." },
  { q: "최대 리스크", a: "① WTP ② AI 실행 신뢰 ③ 한 루프 집중. 90일 목표가 정확히 이 세 가지를 검증합니다." },
];

function SlideAppA(_: SlideProps) {
  return (
    <section className="slide hy-appendix">
      <Header eyebrow="APPENDIX A — Q&A" title="핵심 질문 · 핵심 답변" />
      <motion.div className="hy-qa-grid" variants={stagger(0.07, 0.3)} initial="hidden" animate="show">
        {qanda.map((item) => (
          <motion.div key={item.q} variants={fadeUp} className="hy-qa-card">
            <b className="hy-qa-q">{item.q}</b>
            <p className="hy-qa-a">{item.a}</p>
          </motion.div>
        ))}
      </motion.div>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   APPENDIX B — 유닛이코노믹스 풀 테이블
   ──────────────────────────────────────────────────────────── */
function SlideAppB(_: SlideProps) {
  return (
    <section className="slide hy-appendix">
      <Header eyebrow="APPENDIX B — UNIT ECONOMICS" title="유닛이코노믹스 원자료" />
      <motion.div className="hy-app-table-wrap" initial={{ opacity: 0, y: 14 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.3, ease: EASE_OUT }}>
        <table className="hy-table hy-app-table">
          <thead>
            <tr>
              <th>항목</th>
              <th>기준</th>
              <th>단가</th>
              <th>월 10h COGS</th>
            </tr>
          </thead>
          <tbody>
            <tr><td>STT batch</td><td>ElevenLabs Scribe</td><td>$0.22/h</td><td>$2.20</td></tr>
            <tr><td>STT realtime</td><td>ElevenLabs Scribe</td><td>$0.39/h</td><td>(참고: 월 30h → $11.7)</td></tr>
            <tr><td>LLM (라우팅)</td><td>저위험=소형 모델</td><td>가변</td><td>$0.80</td></tr>
            <tr><td>결제 수수료</td><td>~3%</td><td>—</td><td>$0.28</td></tr>
            <tr><td>인프라·저장</td><td>벡터·스토리지</td><td>—</td><td>$0.15</td></tr>
            <tr className="is-bold"><td>합계 COGS</td><td>월 10h</td><td>—</td><td>$3.43</td></tr>
            <tr className="is-bold"><td>Gross Margin</td><td>Pro $9.35 기준</td><td>—</td><td>≈ 63%</td></tr>
          </tbody>
        </table>
        <div className="hy-app-note">
          <p>환율 1 USD = 1,380 KRW · Pro 12,900원 = $9.35 · Team 19,900원 = $14.4</p>
          <p>경쟁가 환산: Bond $99 = 136,620원 · Dimension $29 = 40,020원</p>
          <p>헤비유저 리스크: 월 30h → STT만 $6.6 → 개인 요금제 마진 붕괴 → 사용량 캡 또는 팀 전환 유도</p>
          <p>월 30h breakeven ≈ 팀 19,900원/좌석 이상에서 성립</p>
        </div>
      </motion.div>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   APPENDIX C — 경쟁사 펀딩 출처 + 보안 상세
   ──────────────────────────────────────────────────────────── */
function SlideAppC(_: SlideProps) {
  return (
    <section className="slide hy-appendix">
      <Header eyebrow="APPENDIX C — SOURCES + SECURITY" title="출처 · 보안 상세" />
      <motion.div className="hy-app-cols" variants={stagger(0.1, 0.3)} initial="hidden" animate="show">
        <motion.div variants={fadeUp} className="hy-app-col">
          <h3>경쟁사 펀딩 출처</h3>
          <ul className="hy-app-list">
            <li><b>Bond</b> — 시드 $3M (Fellows Fund, 2025.12), YC X25. ≈41억원 @1,380.</li>
            <li><b>Dimension</b> — $2M+ (GitHub·Pitch·Netlify·Framer·Postman·WorkOS 창업자). 창업자 Tejas Ravishankar(19). 2026.5.20 winding down. ≈28억원.</li>
            <li><b>a16z</b> — AI CoS 공개 모집 / <b>YC RFS</b> "company brain" 2회 — Bond 창업자 에세이 2026.5.</li>
            <li><b>시장</b> — Grand View Research, AI assistant software, 2024 $8.46B → 2033 $35.7B, CAGR ~17%.</li>
          </ul>
        </motion.div>
        <motion.div variants={fadeUp} className="hy-app-col">
          <h3>보안 상세</h3>
          <p className="hy-app-sub">현재 보유</p>
          <ul className="hy-app-list">
            <li>전송·저장 암호화</li>
            <li>사용자 데이터 모델 학습 미사용</li>
            <li>전 행동 audit log</li>
            <li>사용자 삭제권</li>
          </ul>
          <p className="hy-app-sub">기업 로드맵 — 미보유, 명시적 목표</p>
          <ul className="hy-app-list">
            <li>SOC 2 Type II</li>
            <li>SSO · SCIM · RBAC</li>
            <li>한국 리전 · on-prem 검토</li>
          </ul>
          <Honesty tone="muted">
            ARCA는 사용자가 위임한 도구로 <b>투명하게</b> 일합니다. 신뢰는 "안 틀린다"가 아니라 "보이고·되돌릴 수 있고·위험한 건 승인 없이 안 나간다"에서.
          </Honesty>
        </motion.div>
      </motion.div>
    </section>
  );
}

/* ────────────────────────────────────────────────────────────
   Deck registry
   ──────────────────────────────────────────────────────────── */
const slides: SlideDef[] = [
  // Main deck
  { id: "hy-title",    title: "ARCA",                  durationSec: 30,  Component: Slide01Title },
  { id: "hy-problem",  title: "병목",                   durationSec: 50,  Component: Slide02Problem },
  { id: "hy-data",     title: "57 / 43 / 68%",          durationSec: 55,  Component: Slide03Data },
  { id: "hy-field",    title: "40 인터뷰",               durationSec: 55,  Component: Slide04Field },
  { id: "hy-funding",  title: "Funding landscape",      durationSec: 60,  Component: Slide05Funding },
  { id: "hy-wedge",    title: "Wedge",                  durationSec: 50,  Component: Slide06Wedge },
  { id: "hy-demo",     title: "Action Pack",             durationSec: 180, Component: Slide07Demo },
  { id: "hy-category", title: "Handoff",                durationSec: 45,  Component: Slide08Category },
  { id: "hy-compete",  title: "Competitor matrix",      durationSec: 70,  Component: Slide09Matrix },
  { id: "hy-loop",     title: "Context loop",           durationSec: 60,  Component: Slide10Loop },
  { id: "hy-market",   title: "Market + SOM",           durationSec: 50,  Component: Slide11Market },
  { id: "hy-unit",     title: "Pricing / COGS",         durationSec: 70,  Component: Slide12Pricing },
  { id: "hy-biz",      title: "Business Model",         durationSec: 55,  Component: Slide13BizModel },
  { id: "hy-traction", title: "Traction vs Risk",       durationSec: 60,  Component: Slide13Traction },
  { id: "hy-team",     title: "Team · velocity",        durationSec: 55,  Component: Slide14Team },
  { id: "hy-gtm",      title: "GTM 성장전략",            durationSec: 50,  Component: Slide15GTM },
  { id: "hy-ask",      title: "Ask 2억 · pre-seed",     durationSec: 45,  Component: Slide16Ask },
  { id: "hy-next",     title: "Next 90 days",           durationSec: 40,  Component: Slide17Next },
  { id: "hy-roadmap",  title: "12개월 로드맵",           durationSec: 55,  Component: Slide_Roadmap },
  { id: "hy-moat",     title: "Moat",                   durationSec: 55,  Component: Slide18Moat },
  { id: "hy-close",    title: "arca 해놔",               durationSec: 50,  Component: Slide19Close },
  // Appendix (flip-to Q&A backup)
  { id: "hy-app-a",    title: "APPENDIX · Q&A",         durationSec: 0,   Component: SlideAppA },
  { id: "hy-app-b",    title: "APPENDIX · 유닛이코노믹스", durationSec: 0,   Component: SlideAppB },
  { id: "hy-app-c",    title: "APPENDIX · 출처·보안",    durationSec: 0,   Component: SlideAppC },
];

export default function HyundaiPitchPage() {
  return <Deck slides={slides} tag="ARCA · HYUNDAI ZER01NE" />;
}
