"use client";

import { useEffect, useRef, useState } from "react";
import {
  motion,
  AnimatePresence,
  useMotionValue,
  useScroll,
  useSpring,
  useTransform,
  useVelocity,
} from "framer-motion";
import "./arca.css";

/* Served from thezonebio.com/arca via rewrite — API calls hit arca origin. */
const ARCA_ORIGIN = "https://arca-the-zone-bio.vercel.app";
function base(): string {
  if (typeof window === "undefined") return "";
  const h = window.location.hostname;
  return h === "localhost" || h.endsWith(".vercel.app") ? "" : ARCA_ORIGIN;
}

const EASE = [0.22, 1, 0.36, 1] as const;

/* ═══ Spirit — the ARCA character ═══════════════════════════
   Parametrizable companion: colors per agent, idle bob + blink,
   optional cursor-following eyes, party mode. */

type SpiritColors = { hi: string; mid: string; lo: string; fin: string };

const ORANGE: SpiritColors = { hi: "#ff9d6b", mid: "#f75b2b", lo: "#e2331a", fin: "#e2331a" };

function Spirit({
  colors = ORANGE,
  size = 96,
  mood = "idle",
  followCursor = false,
  bobDelay = 0,
}: {
  colors?: SpiritColors;
  size?: number;
  mood?: "idle" | "party";
  followCursor?: boolean;
  bobDelay?: number;
}) {
  const px = useMotionValue(0);
  const py = useMotionValue(0);
  const ex = useSpring(px, { stiffness: 120, damping: 16 });
  const ey = useSpring(py, { stiffness: 120, damping: 16 });
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!followCursor) return;
    function onMove(e: MouseEvent) {
      const el = ref.current;
      if (!el) return;
      const r = el.getBoundingClientRect();
      const cx = r.left + r.width / 2;
      const cy = r.top + r.height / 2;
      px.set(Math.max(-5, Math.min(5, (e.clientX - cx) / 40)));
      py.set(Math.max(-4, Math.min(4, (e.clientY - cy) / 40)));
    }
    window.addEventListener("mousemove", onMove);
    return () => window.removeEventListener("mousemove", onMove);
  }, [followCursor, px, py]);

  const uid = useRef(`s${Math.round(size)}-${colors.mid.slice(1)}`).current;

  return (
    <motion.div
      ref={ref}
      className="spirit"
      style={{ width: size, height: size }}
      animate={
        mood === "party"
          ? { y: [0, -size * 0.3, 0, -size * 0.16, 0], rotate: [0, -10, 10, -5, 0] }
          : { y: [0, -size * 0.07, 0] }
      }
      transition={
        mood === "party"
          ? { duration: 1.1, ease: "easeOut", repeat: 1 }
          : { duration: 2.6, repeat: Infinity, ease: "easeInOut", delay: bobDelay }
      }
    >
      <svg viewBox="0 0 100 100">
        <defs>
          <radialGradient id={`${uid}-body`} cx="36%" cy="30%" r="80%">
            <stop offset="0%" stopColor={colors.hi} />
            <stop offset="55%" stopColor={colors.mid} />
            <stop offset="100%" stopColor={colors.lo} />
          </radialGradient>
          <linearGradient id={`${uid}-eye`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#fff6ec" />
            <stop offset="100%" stopColor="#ffe3c9" />
          </linearGradient>
        </defs>

        <motion.g
          animate={{ rotate: [-6, 8, -6] }}
          transition={{ duration: 1.8, repeat: Infinity, ease: "easeInOut", delay: bobDelay }}
          style={{ originX: "18px", originY: "62px" }}
        >
          <ellipse cx="12" cy="62" rx="9" ry="6" fill={colors.fin} />
        </motion.g>
        <motion.g
          animate={{ rotate: [6, -8, 6] }}
          transition={{ duration: 1.8, repeat: Infinity, ease: "easeInOut", delay: bobDelay }}
          style={{ originX: "82px", originY: "62px" }}
        >
          <ellipse cx="88" cy="62" rx="9" ry="6" fill={colors.fin} />
        </motion.g>

        <path d="M64 16 L78 8 L74 26 Z" fill={colors.lo} />
        <circle cx="50" cy="56" r="34" fill={`url(#${uid}-body)`} />
        <ellipse cx="38" cy="40" rx="12" ry="8" fill="rgba(255,255,255,0.28)" />

        {mood === "party" ? (
          <g stroke="#fff6ec" strokeWidth="5.5" strokeLinecap="round" fill="none">
            <path d="M30 54 Q37 46 44 54" />
            <path d="M56 54 Q63 46 70 54" />
          </g>
        ) : (
          <motion.g
            style={followCursor ? { x: ex, y: ey } : undefined}
            animate={{ scaleY: [1, 1, 0.08, 1, 1] }}
            transition={{
              duration: 3.6,
              times: [0, 0.9, 0.94, 0.98, 1],
              repeat: Infinity,
              delay: bobDelay * 1.7,
            }}
          >
            <path d="M28 58 Q28 44 37 44 Q46 44 46 58 Z" fill={`url(#${uid}-eye)`} />
            <path d="M54 58 Q54 44 63 44 Q72 44 72 58 Z" fill={`url(#${uid}-eye)`} />
          </motion.g>
        )}
      </svg>
    </motion.div>
  );
}

/* Scroll rider — small spirit that rides the right edge */
function Rider() {
  const { scrollY, scrollYProgress } = useScroll();
  const v = useVelocity(scrollY);
  const top = useSpring(useTransform(scrollYProgress, [0, 1], ["16vh", "78vh"]), {
    stiffness: 55,
    damping: 16,
  });
  const squish = useSpring(useTransform(v, [-2400, 0, 2400], [1.14, 1, 0.82]), {
    stiffness: 320,
    damping: 22,
  });
  return (
    <motion.div className="rider" style={{ top }} aria-hidden="true">
      <motion.div style={{ scaleY: squish, originY: 1 }}>
        <Spirit size={54} />
      </motion.div>
    </motion.div>
  );
}

/* ═══ Typing loop ═══ */

const COMMANDS = [
  "wrap up this meeting",
  "follow up with everyone I met today",
  "prep tomorrow's pitch",
  "remember this decision",
  "clear my inbox",
];

function TypeLoop() {
  const [text, setText] = useState("");
  useEffect(() => {
    let phrase = 0;
    let i = 0;
    let deleting = false;
    const id = setInterval(() => {
      const full = COMMANDS[phrase];
      if (!deleting) {
        i++;
        if (i >= full.length) {
          i = full.length;
          deleting = true;
          setText(full.slice(0, i));
          return;
        }
      } else {
        i -= 3;
        if (i <= 0) {
          i = 0;
          deleting = false;
          phrase = (phrase + 1) % COMMANDS.length;
        }
      }
      setText(COMMANDS[phrase].slice(0, Math.max(0, i)));
    }, 90);
    return () => clearInterval(id);
  }, []);
  return (
    <div className="type-pill">
      <span className="type-verb">arca it —</span>
      <span className="type-text">{text}</span>
      <span className="type-caret" />
    </div>
  );
}

/* ═══ OS demo window — the delegation pipeline, looping ═══ */

const DEMO_ACTIONS = ["Summary → Notion", "3 follow-up emails drafted", "Action items → Slack #team"];

function DemoWindow() {
  const [step, setStep] = useState(0);
  useEffect(() => {
    const id = setInterval(() => setStep((s) => (s + 1) % 8), 1150);
    return () => clearInterval(id);
  }, []);

  return (
    <div className="demo-window">
      <div className="demo-bar">
        <i /><i /><i />
        <span>ARCA — command surface</span>
      </div>
      <div className="demo-body">
        <motion.div
          className="demo-msg demo-user"
          animate={{ opacity: step >= 0 ? 1 : 0, y: step >= 0 ? 0 : 8 }}
        >
          <b>you</b> arca it — wrap up this meeting
        </motion.div>

        <AnimatePresence>
          {step >= 1 && (
            <motion.div
              className="demo-msg demo-arca"
              initial={{ opacity: 0, y: 10 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0 }}
            >
              <span className="demo-avatar">
                <Spirit size={26} />
              </span>
              <div>
                <b>ARCA</b> on it. transcribing 47 min, 4 speakers…
                {step >= 2 && (
                  <motion.div className="demo-transcript" initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
                    {["“Let's lock the Q3 roadmap…”", "“Jane owns the pilot with Hyundai…”", "“Ship the beta by the 21st.”"].map(
                      (l, i) => (
                        <motion.p
                          key={l}
                          initial={{ opacity: 0, x: -8 }}
                          animate={{ opacity: step >= 2 + i * 0 ? 1 : 0, x: 0 }}
                          transition={{ delay: i * 0.25 }}
                        >
                          {l}
                        </motion.p>
                      )
                    )}
                  </motion.div>
                )}
              </div>
            </motion.div>
          )}
        </AnimatePresence>

        <div className="demo-actions">
          {DEMO_ACTIONS.map((a, i) => (
            <motion.div
              key={a}
              className="demo-action"
              initial={false}
              animate={{
                opacity: step >= 3 + i ? 1 : 0,
                x: step >= 3 + i ? 0 : -12,
              }}
              transition={{ duration: 0.35, ease: EASE }}
            >
              <motion.span
                className="demo-tick"
                initial={false}
                animate={{ scale: step >= 3 + i ? [0, 1.3, 1] : 0 }}
                transition={{ duration: 0.4 }}
              >
                ✓
              </motion.span>
              {a}
            </motion.div>
          ))}
        </div>

        <AnimatePresence>
          {step >= 6 && (
            <motion.div
              className="demo-done"
              initial={{ opacity: 0, scale: 0.9 }}
              animate={{ opacity: 1, scale: 1 }}
              exit={{ opacity: 0 }}
              transition={{ type: "spring", stiffness: 300, damping: 20 }}
            >
              done in 42s — you never left flow ⚡
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </div>
  );
}

/* ═══ Memory recall demo, looping Q&A ═══ */

const RECALLS: Array<{ q: string; a: string; meta: string }> = [
  {
    q: "Who did I meet at BZCF demo day?",
    a: "Kim Chulsoo — you talked about AI hardware. He asked for the deck.",
    meta: "Jul 4 · Seoul · via ARCA Ring",
  },
  {
    q: "What did we decide about pricing?",
    a: "Founding members lock $19/mo for life. Decided in Tuesday's standup.",
    meta: "Jul 1 · meeting memory",
  },
  {
    q: "When did I last talk to Jane?",
    a: "11 days ago — she owes you pilot numbers. Want me to nudge her?",
    meta: "Jun 23 · Slack + email memory",
  },
];

function RecallDemo() {
  const [i, setI] = useState(0);
  useEffect(() => {
    const id = setInterval(() => setI((x) => (x + 1) % RECALLS.length), 4200);
    return () => clearInterval(id);
  }, []);
  const r = RECALLS[i];
  return (
    <div className="recall">
      <AnimatePresence mode="wait">
        <motion.div
          key={i}
          initial={{ opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -10 }}
          transition={{ duration: 0.4, ease: EASE }}
        >
          <div className="recall-q">{r.q}</div>
          <div className="recall-a">
            <span className="recall-spirit">
              <Spirit size={30} />
            </span>
            <div>
              <p>{r.a}</p>
              <small>{r.meta}</small>
            </div>
          </div>
        </motion.div>
      </AnimatePresence>
      <div className="recall-dots">
        {RECALLS.map((_, d) => (
          <i key={d} className={d === i ? "on" : ""} />
        ))}
      </div>
    </div>
  );
}

/* ═══ Agents ═══ */

const AGENTS: Array<{ name: string; role: string; colors: SpiritColors }> = [
  { name: "ARCA", role: "Your second self. Orchestrates everything.", colors: ORANGE },
  { name: "MILO", role: "Finance & markets. Watches every number.", colors: { hi: "#7da9f5", mid: "#477ee9", lo: "#2f5fc4", fin: "#2f5fc4" } },
  { name: "PIXEL", role: "Design & brand. Ships the pixels.", colors: { hi: "#ff7d9c", mid: "#fb2d54", lo: "#d11840", fin: "#d11840" } },
  { name: "VOX", role: "Meetings & voice. Never misses a word.", colors: { hi: "#6fe0a2", mid: "#34c771", lo: "#1f9e54", fin: "#1f9e54" } },
  { name: "SILO", role: "Ops & inventory. Keeps the machine fed.", colors: { hi: "#ffd37a", mid: "#f0a72b", lo: "#c97f0e", fin: "#c97f0e" } },
];

/* ═══ Pricing ═══ */

const TIERS = [
  {
    name: "Companion",
    price: "$0",
    per: "forever",
    tag: "",
    features: ["1 companion, fully yours", "Personal memory layer", "50 delegations / month", "iPhone + Mac"],
    cta: "Join the waitlist",
    href: "#waitlist",
  },
  {
    name: "Second Self",
    price: "$19",
    per: "/mo · founding price",
    tag: "MOST LOVED",
    features: [
      "Unlimited “arca it” delegation",
      "Full device mesh — Watch, Ring too",
      "Slack · Notion · Gmail · Obsidian",
      "Flow Guardian answers for you",
      "Founding price locked for life",
    ],
    cta: "Get early access",
    href: "#waitlist",
  },
  {
    name: "ZONE for Teams",
    price: "$99",
    per: "/seat · /mo",
    tag: "",
    features: [
      "Characterized company agents",
      "Hatch MILO, PIXEL, VOX & yours",
      "Shared team memory",
      "Agent-to-agent workflows",
      "Admin, SSO, audit",
    ],
    cta: "Talk to us",
    href: "mailto:me@thezonebio.com?subject=ZONE%20for%20Teams",
  },
];

/* ═══ Page ═══ */

export default function ArcaLanding() {
  const [wlEmail, setWlEmail] = useState("");
  const [wlPhase, setWlPhase] = useState<"idle" | "sending" | "done" | "error">("idle");
  const [heroMood, setHeroMood] = useState<"idle" | "party">("idle");
  // Resolved after mount so SSR and client agree (base() reads window).
  const [productHref, setProductHref] = useState("/");
  useEffect(() => {
    setProductHref(`${base()}/` || "/");
  }, []);

  async function joinWaitlist(e: React.FormEvent) {
    e.preventDefault();
    if (!wlEmail.trim()) return;
    setWlPhase("sending");
    try {
      const res = await fetch(`${base()}/api/ring/waitlist`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email: wlEmail.trim(), source: "arca-landing" }),
      });
      if (!res.ok) throw new Error("failed");
      setWlPhase("done");
      setHeroMood("party");
      setTimeout(() => setHeroMood("idle"), 2600);
    } catch {
      setWlPhase("error");
    }
  }

  return (
    <div className="arca-root">
      <Rider />

      {/* ── Nav ── */}
      <nav className="a-nav">
        <a className="a-logo" href="#top">
          <Spirit size={30} />
          <b>ARCA</b>
        </a>
        <div className="a-nav-links">
          <a href="#demo">Product</a>
          <a href="#agents">Agents</a>
          <a href="#pricing">Pricing</a>
        </div>
        <a className="a-nav-cta" href="#waitlist">
          Get early access
        </a>
      </nav>

      {/* ── Hero ── */}
      <header className="a-hero" id="top">
        <motion.div
          className="a-hero-copy"
          initial="hidden"
          animate="show"
          variants={{ show: { transition: { staggerChildren: 0.1 } } }}
        >
          <motion.p className="a-eyebrow" variants={{ hidden: { opacity: 0, y: 12 }, show: { opacity: 1, y: 0 } }}>
            YOUR SECOND SELF · AGI COMPANION OS
          </motion.p>
          <motion.h1 variants={{ hidden: { opacity: 0, y: 16 }, show: { opacity: 1, y: 0 } }} transition={{ duration: 0.5, ease: EASE }}>
            It remembers
            <br />
            everything.
            <br />
            <em>So you don&apos;t have to.</em>
          </motion.h1>
          <motion.p className="a-lede" variants={{ hidden: { opacity: 0, y: 12 }, show: { opacity: 1, y: 0 } }}>
            ARCA lives across your devices, remembers every meeting, every person, every decision — and does the work
            you hand it with two words.
          </motion.p>
          <motion.div variants={{ hidden: { opacity: 0, y: 12 }, show: { opacity: 1, y: 0 } }}>
            <TypeLoop />
          </motion.div>
          <motion.div className="a-hero-ctas" variants={{ hidden: { opacity: 0, y: 12 }, show: { opacity: 1, y: 0 } }}>
            <a className="a-btn" href="#waitlist">
              Join the waitlist
            </a>
            <a className="a-btn-ghost" href="#demo">
              Watch it work ↓
            </a>
          </motion.div>
        </motion.div>

        <motion.div
          className="a-hero-spirit"
          initial={{ opacity: 0, scale: 0.6 }}
          animate={{ opacity: 1, scale: 1 }}
          transition={{ type: "spring", stiffness: 180, damping: 18, delay: 0.25 }}
        >
          <div className="a-halo" />
          <Spirit size={210} followCursor mood={heroMood} />
          {[0, 1, 2].map((i) => (
            <motion.span
              key={i}
              className="a-spark"
              style={{ top: `${16 + i * 26}%`, left: i % 2 ? "82%" : "4%" }}
              animate={{ y: [0, -12, 0], opacity: [0.4, 1, 0.4], scale: [0.8, 1.15, 0.8] }}
              transition={{ duration: 2.4, delay: i * 0.5, repeat: Infinity, ease: "easeInOut" }}
            />
          ))}
        </motion.div>
      </header>

      {/* ── Demo ── */}
      <section className="a-section" id="demo">
        <motion.div
          className="a-section-head"
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.5, ease: EASE }}
        >
          <p className="a-eyebrow">TOTAL DELEGATION</p>
          <h2>
            Say <em>“arca it.”</em> Walk away.
          </h2>
          <p className="a-sub">
            Not a chatbot you babysit. A companion that owns the whole job — transcribe, decide, draft, file, follow up
            — and reports back when it&apos;s done.
          </p>
        </motion.div>
        <motion.div
          initial={{ opacity: 0, y: 30 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-60px" }}
          transition={{ duration: 0.55, ease: EASE }}
        >
          <DemoWindow />
        </motion.div>
        <motion.div
          className="a-demo-cta"
          initial={{ opacity: 0, y: 16 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-40px" }}
          transition={{ duration: 0.45, ease: EASE }}
        >
          <a className="a-btn" href={productHref}>
            Not a mockup — try the live demo →
          </a>
        </motion.div>
      </section>

      {/* ── Memory ── */}
      <section className="a-section a-memory">
        <motion.div
          className="a-section-head"
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.5, ease: EASE }}
        >
          <p className="a-eyebrow">MEMORY LAYER</p>
          <h2>
            A memory for <em>your whole life.</em>
          </h2>
          <p className="a-sub">
            Every conversation, handshake, and decision becomes memory — searchable in plain language, shared with the
            people and agents you choose.
          </p>
        </motion.div>
        <motion.div
          initial={{ opacity: 0, y: 30 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-60px" }}
          transition={{ duration: 0.55, ease: EASE }}
        >
          <RecallDemo />
        </motion.div>
      </section>

      {/* ── Agents ── */}
      <section className="a-section" id="agents">
        <motion.div
          className="a-section-head"
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.5, ease: EASE }}
        >
          <p className="a-eyebrow">ZONE FOR TEAMS</p>
          <h2>
            Hatch your company&apos;s <em>agents.</em>
          </h2>
          <p className="a-sub">
            Every team gets a characterized agent — its own memory, personality, and job. They work with each other.
            You just talk to ARCA.
          </p>
        </motion.div>
        <div className="a-agents">
          {AGENTS.map((a, i) => (
            <motion.div
              key={a.name}
              className="a-agent"
              initial={{ opacity: 0, y: 26 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, margin: "-40px" }}
              transition={{ duration: 0.45, delay: (i % 3) * 0.08, ease: EASE }}
              whileHover={{ y: -8 }}
            >
              <Spirit size={84} colors={a.colors} bobDelay={i * 0.35} />
              <h3>{a.name}</h3>
              <p>{a.role}</p>
            </motion.div>
          ))}
          <motion.a
            className="a-agent a-agent-hatch"
            href="#waitlist"
            initial={{ opacity: 0, y: 26 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-40px" }}
            transition={{ duration: 0.45, delay: 0.24, ease: EASE }}
            whileHover={{ y: -8 }}
          >
            <motion.div
              className="a-egg"
              animate={{ rotate: [-4, 4, -4, 2, 0, 0] }}
              transition={{ duration: 2.2, repeat: Infinity, ease: "easeInOut" }}
            >
              🥚
            </motion.div>
            <h3>YOURS</h3>
            <p>Hatch a companion for your team.</p>
          </motion.a>
        </div>
      </section>

      {/* ── Everywhere ── */}
      <section className="a-section a-everywhere">
        <motion.div
          className="a-section-head"
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.5, ease: EASE }}
        >
          <p className="a-eyebrow">ONE COMPANION, EVERY SCREEN</p>
          <h2>
            It lives <em>everywhere you do.</em>
          </h2>
        </motion.div>
        <div className="a-devices">
          {["⌚ Watch", "📱 iPhone", "💻 Mac", "💍 Ring"].map((d, i) => (
            <motion.div
              key={d}
              className="a-device"
              initial={{ opacity: 0, y: 20 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ delay: i * 0.08, duration: 0.4, ease: EASE }}
            >
              {d}
            </motion.div>
          ))}
          <motion.div
            className="a-hopper"
            animate={{ left: ["6%", "34%", "62%", "90%", "62%", "34%", "6%"], y: [0, -34, 0, -34, 0, -34, 0] }}
            transition={{ duration: 6.4, repeat: Infinity, ease: "easeInOut" }}
          >
            <Spirit size={44} />
          </motion.div>
        </div>
      </section>

      {/* ── Pricing ── */}
      <section className="a-section" id="pricing">
        <motion.div
          className="a-section-head"
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.5, ease: EASE }}
        >
          <p className="a-eyebrow">PRICING</p>
          <h2>
            Simple pricing for <em>superhuman leverage.</em>
          </h2>
          <p className="a-sub">Founding-member prices, locked for life.</p>
        </motion.div>
        <div className="a-tiers">
          {TIERS.map((t, i) => (
            <motion.div
              key={t.name}
              className={`a-tier${t.tag ? " a-tier-hot" : ""}`}
              initial={{ opacity: 0, y: 28 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, margin: "-40px" }}
              transition={{ duration: 0.5, delay: i * 0.1, ease: EASE }}
              whileHover={{ y: -6 }}
            >
              {t.tag && (
                <>
                  <span className="a-tier-peek">
                    <Spirit size={54} />
                  </span>
                  <span className="a-tier-tag">{t.tag}</span>
                </>
              )}
              <h3>{t.name}</h3>
              <div className="a-price">
                {t.price}
                <small>{t.per}</small>
              </div>
              <ul>
                {t.features.map((f) => (
                  <li key={f}>{f}</li>
                ))}
              </ul>
              <a className={t.tag ? "a-btn" : "a-btn-ghost"} href={t.href}>
                {t.cta}
              </a>
            </motion.div>
          ))}
        </div>
      </section>

      {/* ── Waitlist ── */}
      <section className="a-section a-waitlist" id="waitlist">
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.5, ease: EASE }}
        >
          <div className="a-waitlist-spirit">
            <Spirit size={92} mood={heroMood} />
          </div>
          <h2>
            Ready to meet <em>your second self?</em>
          </h2>
          <p className="a-sub">Your companion is almost ready to hatch. Get in line.</p>

          {wlPhase !== "done" ? (
            <form className="a-wl" onSubmit={joinWaitlist}>
              <input
                value={wlEmail}
                onChange={(e) => setWlEmail(e.target.value)}
                placeholder="you@email.com"
                type="email"
                inputMode="email"
                required
              />
              <motion.button type="submit" disabled={wlPhase === "sending"} whileTap={{ scale: 0.96 }}>
                {wlPhase === "sending" ? "…" : "Join the waitlist"}
              </motion.button>
            </form>
          ) : (
            <motion.p className="a-wl-done" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}>
              You&apos;re in. We&apos;ll email you the moment your companion is ready to hatch ✓
            </motion.p>
          )}
          {wlPhase === "error" && <p className="a-error">Something broke — try again?</p>}
        </motion.div>
      </section>

      <footer className="a-footer">
        <span>ARCA · THE ZONE BIO © 2026</span>
        <a href="/arcaconnect">Tapped Min&apos;s ring? →</a>
      </footer>
    </div>
  );
}
