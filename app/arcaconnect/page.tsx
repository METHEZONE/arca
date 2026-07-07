"use client";

import { useEffect, useRef, useState } from "react";
import { motion, AnimatePresence, useScroll, useSpring, useTransform, useVelocity } from "framer-motion";
import "./ring.css";

/* ─── Owner (public card) ────────────────────────────────── */

const OWNER = {
  fullName: "Minsung Park",
  koreanName: "박민성",
  title: "Founder, THE ZONE BIO · Building ARCA",
  email: "me@thezonebio.com",
  phone: "+82 10-9942-7360",
  instagram: "minthezone",
  linkedin: "minsungparkzone",
  x: "methezone",
};

const DEFAULT_CATEGORY = "26 BZCF Fellow";
const PROFILE_KEY = "arca-ring-profile";
const HISTORY_KEY = "arca-ring-history";

// This page is also served from thezonebio.com/arcaconnect via rewrite —
// API calls and assets must then hit the arca origin directly.
const ARCA_ORIGIN = "https://arca-the-zone-bio.vercel.app";
function base(): string {
  if (typeof window === "undefined") return "";
  const h = window.location.hostname;
  return h === "localhost" || h.endsWith(".vercel.app") ? "" : ARCA_ORIGIN;
}

type Meeting = { at: string; place?: string };
type Geo = { lat?: number; lng?: number; label?: string };

function loadJSON<T>(key: string): T | null {
  try {
    const raw = localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T) : null;
  } catch {
    return null;
  }
}

function fmt(iso: string): string {
  return new Date(iso).toLocaleString("ko-KR", {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

const EASE = [0.22, 1, 0.36, 1] as const;
const rise = {
  initial: { opacity: 0, y: 18 },
  animate: { opacity: 1, y: 0 },
  transition: { duration: 0.5, ease: EASE },
};

/* ─── Feature vignettes (looping micro-demos) ────────────── */

function MemoryVig() {
  return (
    <div className="vig">
      {[0, 1, 2].map((i) => (
        <motion.div
          key={i}
          className="vig-mem-card"
          style={{ zIndex: 3 - i }}
          animate={{ y: [28, 12 - i * 11, 12 - i * 11, 12 - i * 11], opacity: [0, 1, 1, 0] }}
          transition={{ duration: 4.4, times: [0, 0.18, 0.82, 1], delay: i * 0.55, repeat: Infinity, ease: "easeOut" }}
        >
          <span className="vig-dot" />
          <span className="vig-line" style={{ width: `${62 - i * 14}%` }} />
        </motion.div>
      ))}
    </div>
  );
}

function ArcaItVig() {
  return (
    <div className="vig vig-col">
      <motion.div
        className="vig-bubble"
        animate={{ scale: [0, 1, 1, 1], opacity: [0, 1, 1, 0] }}
        transition={{ duration: 4.8, times: [0, 0.1, 0.9, 1], repeat: Infinity, ease: "easeOut" }}
      >
        “arca it”
      </motion.div>
      <div className="vig-tasks">
        {["회의록 정리", "후속 메일 발송", "일정 등록"].map((t, i) => (
          <motion.div
            key={t}
            className="vig-task"
            animate={{ opacity: [0, 1, 1, 0], x: [-10, 0, 0, 0] }}
            transition={{ duration: 4.8, times: [0, 0.12, 0.9, 1], delay: 0.7 + i * 0.5, repeat: Infinity, ease: "easeOut" }}
          >
            <motion.span
              className="vig-tick"
              animate={{ scale: [0, 1.25, 1, 1, 0] }}
              transition={{ duration: 4.8, times: [0, 0.09, 0.14, 0.9, 1], delay: 1.1 + i * 0.5, repeat: Infinity }}
            >
              ✓
            </motion.span>
            {t}
          </motion.div>
        ))}
      </div>
    </div>
  );
}

function GuardianVig() {
  return (
    <div className="vig">
      <motion.div
        className="vig-shield"
        animate={{ scale: [1, 1.07, 1] }}
        transition={{ duration: 2.2, repeat: Infinity, ease: "easeInOut" }}
      >
        ⛨
      </motion.div>
      {[0, 1, 2, 3].map((i) => (
        <motion.span
          key={i}
          className="vig-noise"
          style={{ top: `${18 + (i % 2) * 46}%`, [i < 2 ? "left" : "right"]: "-8%" } as React.CSSProperties}
          animate={{
            x: i < 2 ? [0, 92, 92] : [0, -92, -92],
            opacity: [0, 1, 0],
            scale: [1, 1, 0.3],
          }}
          transition={{ duration: 2.6, times: [0, 0.7, 1], delay: i * 0.65, repeat: Infinity, ease: "easeIn" }}
        />
      ))}
      <motion.div
        className="vig-focus"
        animate={{ opacity: [0.5, 1, 0.5] }}
        transition={{ duration: 2.2, repeat: Infinity, ease: "easeInOut" }}
      >
        FLOW
      </motion.div>
    </div>
  );
}

function CompanionVig() {
  return (
    <div className="vig">
      <motion.div
        className="vig-orb"
        animate={{ scale: [1, 1.1, 1] }}
        transition={{ duration: 2.8, repeat: Infinity, ease: "easeInOut" }}
      />
      {[0, 1].map((i) => (
        <motion.div
          key={i}
          className="vig-ripple"
          animate={{ scale: [0.6, 2.1], opacity: [0.5, 0] }}
          transition={{ duration: 2.8, delay: i * 1.4, repeat: Infinity, ease: "easeOut" }}
        />
      ))}
    </div>
  );
}

function EverywhereVig() {
  return (
    <div className="vig vig-col">
      <div className="vig-devices">
        {["⌚", "📱", "💻", "💍"].map((d, i) => (
          <motion.span
            key={d}
            className="vig-device"
            animate={{ y: [0, -7, 0], scale: [1, 1.14, 1] }}
            transition={{ duration: 3.2, times: [0, 0.5, 1], delay: i * 0.8, repeat: Infinity, ease: "easeInOut" }}
          >
            {d}
          </motion.span>
        ))}
      </div>
      <div className="vig-track">
        <motion.span
          className="vig-runner"
          animate={{ left: ["4%", "92%"] }}
          transition={{ duration: 3.2, repeat: Infinity, ease: "easeInOut", repeatType: "reverse" }}
        />
      </div>
    </div>
  );
}

function SharedVig() {
  return (
    <div className="vig">
      <span className="vig-face">M</span>
      <div className="vig-wire">
        <motion.div
          className="vig-wire-fill"
          animate={{ scaleX: [0, 1, 1] }}
          transition={{ duration: 4, times: [0, 0.6, 1], repeat: Infinity, ease: "easeInOut" }}
        />
        {[0, 1, 2].map((i) => (
          <motion.span
            key={i}
            className="vig-wire-dot"
            style={{ left: `${25 + i * 25}%` }}
            animate={{ scale: [0, 1.3, 1, 1], opacity: [0, 1, 1, 1] }}
            transition={{ duration: 4, times: [0, 0.12, 0.2, 1], delay: 0.6 + i * 0.7, repeat: Infinity }}
          />
        ))}
      </div>
      <span className="vig-face vig-face-you">YOU</span>
    </div>
  );
}

/* ─── Dokkaebi — scroll companion ─────────────────────────
   A little orange spirit that rides down the right edge as
   you scroll: squishes with scroll speed, eyes follow the
   direction, blinks idly, and jumps for joy on connect. */

function Dokkaebi({ mood }: { mood: "idle" | "party" }) {
  const { scrollY, scrollYProgress } = useScroll();
  const v = useVelocity(scrollY);
  const top = useSpring(useTransform(scrollYProgress, [0, 1], ["14vh", "74vh"]), {
    stiffness: 55,
    damping: 16,
  });
  const squish = useSpring(useTransform(v, [-2400, 0, 2400], [1.14, 1, 0.82]), {
    stiffness: 320,
    damping: 22,
  });
  const eyeShift = useSpring(useTransform(v, [-2400, 0, 2400], [-4, 0, 4]), {
    stiffness: 320,
    damping: 26,
  });

  return (
    <motion.div className="dkb" style={{ top }} aria-hidden="true">
      <motion.div
        animate={
          mood === "party"
            ? { y: [0, -30, 0, -16, 0], rotate: [0, -10, 10, -6, 0] }
            : { y: [0, -5, 0] }
        }
        transition={
          mood === "party"
            ? { duration: 1.1, ease: "easeOut", repeat: 1 }
            : { duration: 2.4, repeat: Infinity, ease: "easeInOut" }
        }
      >
        <motion.svg viewBox="0 0 100 100" style={{ scaleY: squish, originY: 1 }}>
          <defs>
            <radialGradient id="dkb-body" cx="36%" cy="30%" r="80%">
              <stop offset="0%" stopColor="#ff9d6b" />
              <stop offset="55%" stopColor="#f75b2b" />
              <stop offset="100%" stopColor="#e2331a" />
            </radialGradient>
            <linearGradient id="dkb-eye" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="#fff6ec" />
              <stop offset="100%" stopColor="#ffd9b8" />
            </linearGradient>
          </defs>

          {/* fins */}
          <motion.g
            animate={{ rotate: [-6, 8, -6] }}
            transition={{ duration: 1.8, repeat: Infinity, ease: "easeInOut" }}
            style={{ originX: "18px", originY: "62px" }}
          >
            <ellipse cx="12" cy="62" rx="9" ry="6" fill="#e2331a" />
          </motion.g>
          <motion.g
            animate={{ rotate: [6, -8, 6] }}
            transition={{ duration: 1.8, repeat: Infinity, ease: "easeInOut" }}
            style={{ originX: "82px", originY: "62px" }}
          >
            <ellipse cx="88" cy="62" rx="9" ry="6" fill="#e2331a" />
          </motion.g>

          {/* horn (도깨비 뿔) */}
          <path d="M64 16 L78 8 L74 26 Z" fill="#c92c12" />

          {/* body */}
          <circle cx="50" cy="56" r="34" fill="url(#dkb-body)" />
          <ellipse cx="38" cy="40" rx="12" ry="8" fill="rgba(255,255,255,0.28)" />

          {/* eyes */}
          {mood === "party" ? (
            <g stroke="#fff6ec" strokeWidth="5.5" strokeLinecap="round" fill="none">
              <path d="M30 54 Q37 46 44 54" />
              <path d="M56 54 Q63 46 70 54" />
            </g>
          ) : (
            <motion.g
              style={{ y: eyeShift }}
              animate={{ scaleY: [1, 1, 0.08, 1, 1] }}
              transition={{ duration: 3.6, times: [0, 0.9, 0.94, 0.98, 1], repeat: Infinity }}
            >
              <path d="M28 58 Q28 44 37 44 Q46 44 46 58 Z" fill="url(#dkb-eye)" />
              <path d="M54 58 Q54 44 63 44 Q72 44 72 58 Z" fill="url(#dkb-eye)" />
            </motion.g>
          )}

          {/* party sparkles */}
          {mood === "party" && (
            <motion.g
              initial={{ opacity: 0 }}
              animate={{ opacity: [0, 1, 0], scale: [0.6, 1.25, 1.5] }}
              transition={{ duration: 1, repeat: 1 }}
              fill="#ffb27a"
            >
              <circle cx="14" cy="24" r="3" />
              <circle cx="88" cy="30" r="2.5" />
              <circle cx="80" cy="88" r="3" />
              <circle cx="16" cy="86" r="2.5" />
            </motion.g>
          )}
        </motion.svg>
      </motion.div>
    </motion.div>
  );
}

const FEATURES: Array<[string, string, () => React.ReactElement]> = [
  ["Memory Layer", "만난 사람, 나눈 대화, 내린 결정 — 전부 기억하는 두 번째 뇌", MemoryVig],
  ["arca it", "한마디로 일 전체를 위임해요. 회의록, 후속 조치, 문서까지 알아서", ArcaItVig],
  ["Flow Guardian", "몰입을 지키는 수호자 — 인터럽트를 대신 받아 처리해요", GuardianVig],
  ["Companion OS", "온보딩에서 나를 아는 AGI 컴패니언이 부화해요", CompanionVig],
  ["Everywhere", "Watch · iPhone · MacBook · Ring, 모든 하드웨어에 살아요", EverywhereVig],
  ["Shared Memory", "오늘 우리의 connect처럼, 관계의 역사가 쌓여요", SharedVig],
];

/* ─── Page ───────────────────────────────────────────────── */

export default function RingPage() {
  const [name, setName] = useState("");
  const [affiliation, setAffiliation] = useState("");
  const [phone, setPhone] = useState("");
  const [email, setEmail] = useState("");
  const [note, setNote] = useState("");
  const [category, setCategory] = useState(DEFAULT_CATEGORY);

  const [geo, setGeo] = useState<Geo | null>(null);
  const [history, setHistory] = useState<Meeting[]>([]);
  const [phase, setPhase] = useState<"form" | "sending" | "connected">("form");
  const [error, setError] = useState("");
  const [connectedAt, setConnectedAt] = useState("");
  const [copied, setCopied] = useState("");
  const [photoUrl, setPhotoUrl] = useState("");
  const [assetBase, setAssetBase] = useState("");

  const [wlEmail, setWlEmail] = useState("");
  const [wlPhase, setWlPhase] = useState<"idle" | "sending" | "done" | "error">("idle");
  const [mood, setMood] = useState<"idle" | "party">("idle");
  const geoRef = useRef<Geo | null>(null);

  function celebrate() {
    setMood("party");
    setTimeout(() => setMood("idle"), 2600);
  }

  useEffect(() => {
    setAssetBase(base());
    // Probe the photo after mount — an SSR'd <img onError> can fire before
    // hydration attaches the listener, leaving a broken-image icon.
    const probe = new Image();
    const url = `${base()}/ring/min.png`;
    probe.onload = () => setPhotoUrl(url);
    probe.src = url;
    const profile = loadJSON<{ name?: string; affiliation?: string; phone?: string; email?: string }>(PROFILE_KEY);
    if (profile) {
      setName(profile.name ?? "");
      setAffiliation(profile.affiliation ?? "");
      setPhone(profile.phone ?? "");
      setEmail(profile.email ?? "");
    }
    setHistory(loadJSON<Meeting[]>(HISTORY_KEY) ?? []);

    if ("geolocation" in navigator) {
      navigator.geolocation.getCurrentPosition(
        async (pos) => {
          const g: Geo = { lat: pos.coords.latitude, lng: pos.coords.longitude };
          try {
            const res = await fetch(
              `https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=${g.lat}&longitude=${g.lng}&localityLanguage=en`
            );
            if (res.ok) {
              const j = await res.json();
              g.label = [j.locality || j.city, j.countryName].filter(Boolean).join(", ");
            }
          } catch {
            /* label optional */
          }
          geoRef.current = g;
          setGeo(g);
        },
        () => {
          /* denied — connect still works without location */
        },
        { enableHighAccuracy: false, timeout: 8000, maximumAge: 300000 }
      );
    }
  }, []);

  const meetCount = history.length + 1;
  const vcardHref = `${assetBase}/api/ring/vcard?at=${encodeURIComponent(connectedAt)}${
    geo?.label ? `&place=${encodeURIComponent(geo.label)}` : ""
  }`;

  async function handleConnect(e: React.FormEvent) {
    e.preventDefault();
    setError("");
    if (!name.trim()) {
      setError("이름을 알려주세요");
      return;
    }
    if (!phone.trim() && !email.trim()) {
      setError("전화번호나 이메일 중 하나는 필요해요");
      return;
    }

    setPhase("sending");
    const now = new Date().toISOString();
    const g = geoRef.current ?? geo ?? undefined;

    try {
      const res = await fetch(`${base()}/api/ring/connect`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: name.trim(),
          affiliation: affiliation.trim() || undefined,
          phone: phone.trim() || undefined,
          email: email.trim() || undefined,
          note: note.trim() || undefined,
          category: category.trim() || DEFAULT_CATEGORY,
          location: g,
          meetCount,
          history: [...history, { at: now, place: g?.label }],
        }),
      });
      if (!res.ok) throw new Error("request failed");

      const newHistory = [...history, { at: now, place: g?.label }];
      try {
        localStorage.setItem(PROFILE_KEY, JSON.stringify({ name, affiliation, phone, email }));
        localStorage.setItem(HISTORY_KEY, JSON.stringify(newHistory));
      } catch {
        /* private mode */
      }
      setHistory(newHistory);
      setConnectedAt(now);
      setPhase("connected");
      celebrate();
      window.scrollTo({ top: 0, behavior: "smooth" });
    } catch {
      setPhase("form");
      setError("전송에 실패했어요. 다시 시도해주세요");
    }
  }

  async function handleWaitlist(e: React.FormEvent) {
    e.preventDefault();
    if (!wlEmail.trim()) return;
    setWlPhase("sending");
    try {
      const res = await fetch(`${base()}/api/ring/waitlist`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email: wlEmail.trim(), name: name.trim() || undefined, source: "ring" }),
      });
      if (!res.ok) throw new Error("failed");
      setWlPhase("done");
      celebrate();
    } catch {
      setWlPhase("error");
    }
  }

  function copy(text: string, tag: string) {
    navigator.clipboard?.writeText(text).then(() => {
      setCopied(tag);
      setTimeout(() => setCopied(""), 1600);
    });
  }

  const unlocked = wlPhase === "done";

  return (
    <div className="ring-root">
      <Dokkaebi mood={mood} />
      <div className="ring-shell">
        {/* ── Hero ── */}
        <motion.header
          className="ring-hero"
          initial="hidden"
          animate="show"
          variants={{ show: { transition: { staggerChildren: 0.09 } } }}
        >
          <motion.div
            className="ring-avatar"
            variants={{ hidden: { opacity: 0, scale: 0.7 }, show: { opacity: 1, scale: 1 } }}
            transition={{ type: "spring", stiffness: 260, damping: 20 }}
          >
            {photoUrl ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={photoUrl} alt="Minsung Park" />
            ) : (
              <span>M</span>
            )}
          </motion.div>
          <motion.p className="ring-eyebrow" variants={{ hidden: { opacity: 0, y: 12 }, show: { opacity: 1, y: 0 } }}>
            ARCA RING
          </motion.p>
          <motion.h1 variants={{ hidden: { opacity: 0, y: 14 }, show: { opacity: 1, y: 0 } }} transition={{ duration: 0.5, ease: EASE }}>
            반가워요,
            <br />
            <em>박민성</em>입니다.
          </motion.h1>
          <motion.p className="ring-title" variants={{ hidden: { opacity: 0, y: 12 }, show: { opacity: 1, y: 0 } }}>
            {OWNER.title}
          </motion.p>
          <motion.div className="ring-chips" variants={{ hidden: { opacity: 0, y: 10 }, show: { opacity: 1, y: 0 } }}>
            <span className="ring-chip">{DEFAULT_CATEGORY}</span>
            {geo?.label && <span className="ring-chip ring-chip-grey">📍 {geo.label}</span>}
          </motion.div>
          {history.length > 0 && phase !== "connected" && (
            <motion.p className="ring-again" {...rise}>
              다시 만났네요 — 이번이 <b>{meetCount}번째</b>예요
            </motion.p>
          )}
        </motion.header>

        <main className="ring-main">
          <AnimatePresence mode="wait">
            {phase !== "connected" ? (
              /* ── Connect ── */
              <motion.section
                key="form"
                className="ring-card"
                initial={{ opacity: 0, y: 18 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -12 }}
                transition={{ duration: 0.4, ease: EASE }}
              >
                <h2>Connect</h2>
                <p className="ring-sub">
                  당신이 누군지 알려주세요.
                  <br />
                  언제 어디서 만났는지까지, 소중히 기억할게요.
                </p>
                <form onSubmit={handleConnect}>
                  <label>
                    <span>이름</span>
                    <input value={name} onChange={(e) => setName(e.target.value)} placeholder="이름을 입력해주세요" autoComplete="name" />
                  </label>
                  <label>
                    <span>소속</span>
                    <input
                      value={affiliation}
                      onChange={(e) => setAffiliation(e.target.value)}
                      placeholder="회사 · 학교 · 팀"
                      autoComplete="organization"
                    />
                  </label>
                  <div className="ring-row">
                    <label>
                      <span>전화</span>
                      <input value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="010-0000-0000" inputMode="tel" autoComplete="tel" />
                    </label>
                    <label>
                      <span>이메일</span>
                      <input value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@email.com" inputMode="email" autoComplete="email" />
                    </label>
                  </div>
                  <label>
                    <span>한 줄 메모</span>
                    <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="오늘 무슨 얘기를 나눴나요?" />
                  </label>
                  <label>
                    <span>우리가 만난 곳</span>
                    <input value={category} onChange={(e) => setCategory(e.target.value)} />
                  </label>
                  {/* honeypot */}
                  <input className="ring-hp" name="company_website" tabIndex={-1} autoComplete="off" aria-hidden="true" />

                  {error && <p className="ring-error">{error}</p>}
                  <motion.button className="ring-cta" type="submit" disabled={phase === "sending"} whileTap={{ scale: 0.97 }}>
                    {phase === "sending" ? "연결하는 중…" : "Connect"}
                  </motion.button>
                  <p className="ring-fine">
                    Connect를 누르면 위 정보가 현재 시간{geo?.label ? ` · 위치(${geo.label})` : ""}와 함께 Min에게 전달되고, Min의
                    연락처가 열립니다.
                  </p>
                </form>
              </motion.section>
            ) : (
              /* ── Connected + Save Min ── */
              <motion.div
                key="done"
                className="ring-stack"
                initial={{ opacity: 0, y: 18 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ duration: 0.45, ease: EASE }}
              >
                <section className="ring-card ring-center">
                  <motion.div
                    className="ring-check"
                    initial={{ scale: 0, rotate: -30 }}
                    animate={{ scale: 1, rotate: 0 }}
                    transition={{ type: "spring", stiffness: 300, damping: 16, delay: 0.15 }}
                  >
                    ✓
                  </motion.div>
                  <h2>Connected</h2>
                  <p className="ring-sub">
                    {fmt(connectedAt)}
                    {geo?.label ? ` · ${geo.label}` : ""}
                    <br />
                    기억할게요.
                    {history.length > 1 && (
                      <>
                        {" "}
                        우리의 <b>{history.length}번째</b> 만남이에요.
                      </>
                    )}
                  </p>
                  {history.length > 1 && (
                    <ol className="ring-timeline">
                      {history.map((h, i) => (
                        <motion.li
                          key={h.at}
                          initial={{ opacity: 0, x: -14 }}
                          animate={{ opacity: 1, x: 0 }}
                          transition={{ delay: 0.3 + i * 0.12, duration: 0.35, ease: EASE }}
                        >
                          <span className="ring-tl-n">{i + 1}</span>
                          {fmt(h.at)}
                          {h.place ? ` · ${h.place}` : ""}
                        </motion.li>
                      ))}
                    </ol>
                  )}
                </section>

                <section className="ring-card">
                  <h2>Save Min</h2>
                  <p className="ring-sub">이제 제 차례예요. 연락처와 링크를 가져가세요.</p>
                  <motion.a className="ring-cta" href={vcardHref} whileTap={{ scale: 0.97 }}>
                    연락처에 저장
                  </motion.a>
                  <div className="ring-list">
                    {(
                      [
                        ["IG", "Instagram", `@${OWNER.instagram}`, `https://instagram.com/${OWNER.instagram}`, ""],
                        ["in", "LinkedIn", `in/${OWNER.linkedin}`, `https://www.linkedin.com/in/${OWNER.linkedin}`, ""],
                        ["𝕏", "X", `@${OWNER.x}`, `https://x.com/${OWNER.x}`, ""],
                        ["☎", "Phone", copied === "phone" ? "복사됐어요 ✓" : OWNER.phone, "", "phone"],
                        ["@", "Email", copied === "email" ? "복사됐어요 ✓" : OWNER.email, "", "email"],
                      ] as Array<[string, string, string, string, string]>
                    ).map(([ic, label, value, href, copyTag], i) => {
                      const inner = (
                        <>
                          <i className="ring-ic">{ic}</i>
                          <div>
                            <b>{label}</b>
                            <small>{value}</small>
                          </div>
                          <u>{href ? "›" : "⧉"}</u>
                        </>
                      );
                      const anim = {
                        initial: { opacity: 0, y: 12 },
                        animate: { opacity: 1, y: 0 },
                        transition: { delay: 0.25 + i * 0.08, duration: 0.35, ease: EASE },
                      };
                      return href ? (
                        <motion.a key={label} href={href} target="_blank" rel="noreferrer" {...anim}>
                          {inner}
                        </motion.a>
                      ) : (
                        <motion.button
                          key={label}
                          type="button"
                          onClick={() => copy(label === "Phone" ? OWNER.phone : OWNER.email, copyTag)}
                          {...anim}
                        >
                          {inner}
                        </motion.button>
                      );
                    })}
                  </div>
                </section>
              </motion.div>
            )}
          </AnimatePresence>

          {/* ── ARCA ── */}
          <motion.section
            className="ring-arca"
            initial={{ opacity: 0, y: 28 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-60px" }}
            transition={{ duration: 0.55, ease: EASE }}
          >
            <p className="ring-eyebrow">WHAT MIN IS BUILDING</p>
            <h2 className="ring-arca-word">ARCA</h2>
            <p className="ring-body">
              ARCA는 <b>AGI 컴패니언</b>이에요. 당신을 아는 <b>second self</b>가 노동을 대신 짊어지고, 당신은 온전히
              좋아하는 것에 몰입하는 세계 — 그게 우리가 만드는 THE ZONE이에요.
            </p>
            <p className="ring-body">
              방금 이 페이지가 우리의 만남을 기억한 것처럼, ARCA는 당신 곁 모든 기기에 살면서 당신의 기억이 됩니다.
            </p>

            {!unlocked ? (
              <form className="ring-wl" onSubmit={handleWaitlist}>
                <input
                  value={wlEmail}
                  onChange={(e) => setWlEmail(e.target.value)}
                  placeholder="이메일을 남기면 피쳐가 열려요"
                  inputMode="email"
                  type="email"
                  required
                />
                <motion.button type="submit" disabled={wlPhase === "sending"} whileTap={{ scale: 0.96 }}>
                  {wlPhase === "sending" ? "…" : "Waitlist"}
                </motion.button>
              </form>
            ) : (
              <motion.p className="ring-wl-done" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}>
                웨잇리스트에 올렸어요. 곧 만나요 ✓
              </motion.p>
            )}
            {wlPhase === "error" && <p className="ring-error">전송 실패 — 다시 시도해주세요</p>}

            {/* Feature blocks: teased through blur until the email unlocks them */}
            <div className={`ring-features${unlocked ? " is-open" : ""}`}>
              {!unlocked && (
                <div className="ring-lock">
                  <span>🔒</span> 이메일을 남기면 열려요
                </div>
              )}
              {FEATURES.map(([title, desc, Vig], i) => (
                <motion.div
                  key={title}
                  className="ring-feature"
                  initial={{ opacity: 0, y: 22 }}
                  whileInView={{ opacity: 1, y: 0 }}
                  viewport={{ once: true, margin: "-30px" }}
                  transition={{ duration: 0.5, delay: (i % 2) * 0.08, ease: EASE }}
                >
                  <Vig />
                  <h3>{title}</h3>
                  <p>{desc}</p>
                </motion.div>
              ))}
            </div>
          </motion.section>

          <footer className="ring-footer">ARCA Ring · THE ZONE BIO © 2026</footer>
        </main>
      </div>
    </div>
  );
}
